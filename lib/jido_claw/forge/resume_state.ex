defmodule JidoClaw.Forge.ResumeState do
  @moduledoc """
  Vendor-CLI session-resume state for armed Forge runners (multica
  MC1-1 port — semantics map `docs/exploration/pms/multica/PORT-MC1-1.md`).

  Treat the struct as opaque: every mutation goes through a transition
  constructor so the cross-field invariants hold by construction —
  poisoned ∧ anchored is unrepresentable (status is one atom), a
  poisoned anchor id is never reused (`rearm_new_anchor/4` refuses it),
  and `retry_used` resets exactly when a new anchor is established.

  ## Anchor lifecycle

      unanchored ──mint_client──────────▶ anchored      (claude: id minted
                 ──capture_backend─────▶ provisional     pre-spawn; codex:
      provisional ──trust──────────────▶ anchored        thread.started is
      any ──poison───────────────────────▶ poisoned      provisional until a
      poisoned ──rearm_new_anchor(≠id)──▶ anchored/      clean exit promotes
                                           provisional   it — CH2-6)
      non-poisoned ──clear(source)──────▶ unanchored

  `clear/2` on a poisoned state is a no-op: poisoning is sticky so the
  poisoned id stays recorded for the never-reuse check; only
  `rearm_new_anchor/4` (with a different id) moves past it.

  ## Stores and codecs

  Copies of this state live at two differently-scoped paths (see
  `docs/system/forge-session-resume.md`):

    * metadata (`metadata["resume"]["state"]` + `["resume"]["guidance"]`)
      — `encode_state/1` + `encode_guidance_marker/1`: the complete
      sanitized anchor state (never guidance text) and the guidance
      status marker `{status, guidance_rev, epoch}`;
    * checkpoint (`runner_state_snapshot["resume"]`) — `encode_state/1`
      + `encode_guidance/1`: same state plus the Vault-encrypted
      guidance text envelope `{"v" => 1, "alg" => "vault", "data" =>
      base64}` (Cloak emits raw binary; the envelope makes it JSON-safe).

  Copies are stamped `{epoch, revision}`; `select/4` merges them —
  anchor state by newest `{epoch, revision}` across both stores,
  guidance status by highest `guidance_rev` within the selected epoch,
  guidance text only ever from a checkpoint copy. No token ever rides a
  copy: the incarnation token is a write capability living in
  `metadata["forge_recovery"]`, threaded to writers, never stored here.

  `repark_reason` is the durable operator-facing re-park marker: set by
  the recovery disposition (`adopt_recovered_guidance/2`) when a parked
  answer could not be restored safely, threaded through BOTH guidance
  codecs so it survives arbitrarily many recoveries, and cleared only
  by `put_guidance/2` (a fresh operator answer).

  Decoding is whitelist-only (`String.to_atom/1` never runs on wire
  data); a garbled copy decodes to `:error` and recovery treats it as
  absent rather than guessing.
  """

  alias JidoClaw.Security.Vault

  @max_session_id_bytes 512
  @max_guidance_bytes 16_384

  @type status :: :unanchored | :provisional | :anchored | :poisoned
  @type ownership :: :client | :backend
  @type session_start_source :: :startup | :resume | :clear | :new | :fork | :compact
  @type guidance_status :: :pending | :inflight | :consumed
  @type guidance :: %{status: guidance_status(), text: String.t() | nil}
  @type repark_reason :: :guidance_text_missing | :inflight_delivery_ambiguous | :corrupt_guidance
  @type guidance_copy :: %{
          status: guidance_status(),
          guidance_rev: non_neg_integer(),
          epoch: non_neg_integer(),
          text: String.t() | nil,
          repark_reason: repark_reason() | nil
        }

  @type t :: %__MODULE__{
          arming: :off | :armed,
          ownership: ownership() | nil,
          status: status(),
          session_id: String.t() | nil,
          workdir: String.t() | nil,
          session_start_source: session_start_source(),
          retry_used: boolean(),
          pending_guidance: guidance() | nil,
          anchored_at: DateTime.t() | nil,
          epoch: non_neg_integer(),
          revision: non_neg_integer(),
          guidance_rev: non_neg_integer(),
          repark_reason: repark_reason() | nil
        }

  defstruct arming: :armed,
            ownership: nil,
            status: :unanchored,
            session_id: nil,
            workdir: nil,
            session_start_source: :startup,
            retry_used: false,
            pending_guidance: nil,
            anchored_at: nil,
            epoch: 0,
            revision: 0,
            guidance_rev: 0,
            repark_reason: nil

  @statuses %{
    "unanchored" => :unanchored,
    "provisional" => :provisional,
    "anchored" => :anchored,
    "poisoned" => :poisoned
  }
  @ownerships %{"client" => :client, "backend" => :backend}
  # fork/compact are herdr HD2-2 vocabulary we accept but never produce.
  @sources %{
    "startup" => :startup,
    "resume" => :resume,
    "clear" => :clear,
    "new" => :new,
    "fork" => :fork,
    "compact" => :compact
  }
  @guidance_statuses %{"pending" => :pending, "inflight" => :inflight, "consumed" => :consumed}
  @repark_reasons %{
    "guidance_text_missing" => :guidance_text_missing,
    "inflight_delivery_ambiguous" => :inflight_delivery_ambiguous,
    "corrupt_guidance" => :corrupt_guidance
  }

  # The static operator-facing prompt for a re-parked answer — the original
  # text is unrecoverable (or unsafe to resend), so the operator re-enters it.
  @repark_prompt "Your previous answer could not be delivered safely; please enter it again."

  # ---- Construction + transitions ----

  @doc """
  A fresh armed state (`session_start_source: :startup`). Options:
  `:workdir`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{workdir: Keyword.get(opts, :workdir)}
  end

  @doc """
  Client-minted anchor (claude fresh-armed: the engine mints the UUID
  and passes `--session-id` pre-spawn). Only from `:unanchored`; a
  poisoned state must go through `rearm_new_anchor/4`.
  """
  @spec mint_client(t(), String.t(), String.t() | nil) :: {:ok, t()} | {:error, atom()}
  def mint_client(%__MODULE__{status: :unanchored} = rs, session_id, workdir) do
    anchor(rs, session_id, workdir, :client)
  end

  def mint_client(%__MODULE__{status: :poisoned}, _id, _workdir), do: {:error, :poisoned}
  def mint_client(%__MODULE__{}, _id, _workdir), do: {:error, :already_anchored}

  @doc """
  Backend-issued anchor (codex `thread.started`): `:provisional` until
  a clean exit calls `trust/1` (CH2-6 — a backend id is not proof the
  session persisted usefully). Only from `:unanchored`.
  """
  @spec capture_backend(t(), String.t(), String.t() | nil) :: {:ok, t()} | {:error, atom()}
  def capture_backend(%__MODULE__{status: :unanchored} = rs, session_id, workdir) do
    with {:ok, anchored} <- anchor(rs, session_id, workdir, :backend) do
      {:ok, %{anchored | status: :provisional}}
    end
  end

  def capture_backend(%__MODULE__{status: :poisoned}, _id, _workdir), do: {:error, :poisoned}
  def capture_backend(%__MODULE__{}, _id, _workdir), do: {:error, :already_anchored}

  @doc """
  Promotes a `:provisional` anchor to `:anchored` (codex clean exit).
  Total: any other status passes through unchanged.
  """
  @spec trust(t()) :: t()
  def trust(%__MODULE__{status: :provisional} = rs),
    do: %{rs | status: :anchored, anchored_at: DateTime.utc_now()}

  def trust(%__MODULE__{} = rs), do: rs

  @doc """
  Drops the anchor and records why (`:clear` explicit, `:new` forced —
  cwd-gate, terminal reuse). Poisoned states are NOT cleared: poisoning
  is sticky (the id must stay recorded for the never-reuse check), so
  this is a no-op there.
  """
  @spec clear(t(), :clear | :new) :: t()
  def clear(%__MODULE__{status: :poisoned} = rs, _source), do: rs

  def clear(%__MODULE__{} = rs, source) when source in [:clear, :new] do
    %{
      rs
      | status: :unanchored,
        session_id: nil,
        ownership: nil,
        anchored_at: nil,
        session_start_source: source
    }
  end

  @doc """
  Marks the anchor poisoned (resume-unsafe failure class). The id is
  retained so `rearm_new_anchor/4` can refuse to reuse it. Total.
  """
  @spec poison(t()) :: t()
  def poison(%__MODULE__{} = rs), do: %{rs | status: :poisoned}

  @doc """
  Establishes a new anchor after poisoning — a later clean fresh run
  MAY anchor again, but never on the poisoned id. Resets `retry_used`
  (the retry latch is per-anchor) and records the start as `:new`.
  `:client` ownership anchors immediately; `:backend` is provisional.
  """
  @spec rearm_new_anchor(t(), String.t(), String.t() | nil, ownership()) ::
          {:ok, t()} | {:error, atom()}
  def rearm_new_anchor(%__MODULE__{status: :poisoned} = rs, session_id, workdir, ownership)
      when ownership in [:client, :backend] do
    if is_binary(session_id) and session_id == rs.session_id do
      {:error, :poisoned_id_reuse}
    else
      fresh = %{rs | status: :unanchored, session_id: nil, session_start_source: :new}

      case ownership do
        :client -> mint_client(fresh, session_id, workdir)
        :backend -> capture_backend(fresh, session_id, workdir)
      end
    end
  end

  def rearm_new_anchor(%__MODULE__{}, _id, _workdir, _ownership), do: {:error, :not_poisoned}

  @doc """
  Latches the one authorized fresh retry for the current anchor. Reset
  only by establishing a new anchor.
  """
  @spec mark_retry_used(t()) :: t()
  def mark_retry_used(%__MODULE__{} = rs), do: %{rs | retry_used: true}

  @doc """
  Records that the current turn continues the anchored session
  (`session_start_source: :resume` — HD2-2).
  """
  @spec continuing(t()) :: t()
  def continuing(%__MODULE__{} = rs), do: %{rs | session_start_source: :resume}

  @doc """
  True when the last turn started a fresh conversation rather than
  continuing the anchored one (`session_start_source` anything but
  `:resume`). Observability only — a mid-run fresh start means prior
  in-conversation context was lost and the turn redid the task fresh.
  """
  @spec fresh_start?(t()) :: boolean()
  def fresh_start?(%__MODULE__{session_start_source: :resume}), do: false
  def fresh_start?(%__MODULE__{}), do: true

  @doc "Stamps the copy-ordering fields (incarnation epoch + revision)."
  @spec stamp(t(), non_neg_integer(), non_neg_integer()) :: t()
  def stamp(%__MODULE__{} = rs, epoch, revision)
      when is_integer(epoch) and epoch >= 0 and is_integer(revision) and revision >= 0 do
    %{rs | epoch: epoch, revision: revision}
  end

  # ---- Guidance lifecycle (pending → inflight → consumed) ----

  @doc """
  Parks operator guidance as `:pending` (`apply_input`). Size-bounded:
  over #{@max_guidance_bytes} bytes is rejected, never truncated.
  """
  @spec put_guidance(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def put_guidance(%__MODULE__{} = rs, text) when is_binary(text) do
    if byte_size(text) <= @max_guidance_bytes do
      # The ONLY clearer of `repark_reason`: a fresh operator answer is what
      # a re-park asked for, so the durable marker self-clears with it.
      {:ok,
       %{
         rs
         | pending_guidance: %{status: :pending, text: text},
           guidance_rev: rs.guidance_rev + 1,
           repark_reason: nil
       }}
    else
      {:error, :guidance_too_large}
    end
  end

  def put_guidance(%__MODULE__{}, _text), do: {:error, :guidance_not_binary}

  @doc """
  Marks pending guidance `:inflight` — the checked transition that must
  persist BEFORE the CLI spawns with the guidance in its prompt.
  """
  @spec guidance_inflight(t()) :: {:ok, t()} | {:error, :no_pending_guidance}
  def guidance_inflight(%__MODULE__{pending_guidance: %{status: :pending, text: text}} = rs) do
    {:ok,
     %{
       rs
       | pending_guidance: %{status: :inflight, text: text},
         guidance_rev: rs.guidance_rev + 1
     }}
  end

  def guidance_inflight(%__MODULE__{}), do: {:error, :no_pending_guidance}

  @doc """
  Marks guidance `:consumed` (text dropped; the marker survives so a
  stale checkpoint copy can never resend an already-answered question).
  Total: a no-guidance state passes through unchanged.
  """
  @spec guidance_consumed(t()) :: t()
  def guidance_consumed(%__MODULE__{pending_guidance: %{}} = rs) do
    %{
      rs
      | pending_guidance: %{status: :consumed, text: nil},
        guidance_rev: rs.guidance_rev + 1
    }
  end

  def guidance_consumed(%__MODULE__{} = rs), do: rs

  @doc "True when guidance is live (pending or inflight)."
  @spec live_guidance?(t()) :: boolean()
  def live_guidance?(%__MODULE__{pending_guidance: %{status: s}}), do: s in [:pending, :inflight]
  def live_guidance?(%__MODULE__{}), do: false

  @doc """
  The inflight guidance text, or nil — the delivery accessor for the
  vendors' continuation turns (`ResumePolicy.take_continuation_guidance/2`).
  """
  @spec inflight_text(t()) :: String.t() | nil
  def inflight_text(%__MODULE__{pending_guidance: %{status: :inflight, text: text}})
      when is_binary(text),
      do: text

  def inflight_text(%__MODULE__{}), do: nil

  @doc """
  Reverts `:inflight` guidance to `:pending` (text kept, `guidance_rev`
  bumped) — the undelivered disposition. ONLY a runner that provably never
  placed the text on an argv may call this (a fresh-armed turn reads
  `state.prompt`, never guidance): reverting a possibly-delivered answer
  would double-send it on the next continuation. Total: any other state
  passes through unchanged.
  """
  @spec guidance_undelivered(t()) :: t()
  def guidance_undelivered(%__MODULE__{pending_guidance: %{status: :inflight, text: text}} = rs)
      when is_binary(text) do
    %{
      rs
      | pending_guidance: %{status: :pending, text: text},
        guidance_rev: rs.guidance_rev + 1
    }
  end

  def guidance_undelivered(%__MODULE__{} = rs), do: rs

  @doc """
  Grafts a conservative re-parkable marker (`:pending`, no text, rev
  bumped) onto a state whose guidance evidence decoded corrupt at
  transplant selection — pending-without-text deterministically re-parks
  at recovery instead of silently erasing the operator's answer. An
  existing `repark_reason` is preserved (it stays authoritative).
  """
  @spec mark_guidance_lost(t()) :: t()
  def mark_guidance_lost(%__MODULE__{} = rs) do
    %{
      rs
      | pending_guidance: %{status: :pending, text: nil},
        guidance_rev: rs.guidance_rev + 1
    }
  end

  @doc "The static operator-facing prompt broadcast/projected for a re-park."
  @spec repark_prompt() :: String.t()
  def repark_prompt, do: @repark_prompt

  @doc """
  The recovery guidance disposition: adopt the transplant checkpoint's
  decoded guidance copy onto the recovered state, returning what recovery
  must do about it. Dispositions, in order:

    * a copy carrying `repark_reason` (any status — practically the
      consumed-graft below) → `{:repark, reason}`, copy restored VERBATIM
      (no re-bump): the persisted reason is AUTHORITATIVE until an answer
      clears it, so a re-parked session that crashes again re-parks again
      instead of recovering `:ready` and dropping the operator request;
    * `:pending` with text → `:restored` (status/text/rev restored — a
      rev-less graft would let this marker out-rev a future re-park's
      fresh answer at a second recovery);
    * `:pending` without text → consume-graft (marker at the copy's rev,
      then `guidance_consumed/1` rev+1) + `{:repark, :guidance_text_missing}`;
    * `:inflight` → same consume-graft + `{:repark,
      :inflight_delivery_ambiguous}` — the answer may already have ridden
      an argv, so it is NEVER resent;
    * `:consumed` (no reason) → `:kept` (marker restored so a stale copy
      can never resend an answered question);
    * `{:error, :corrupt_guidance}` → consume-graft of a SYNTHETIC copy at
      the state's own rev (no decodable copy exists — that is what corrupt
      means) + `{:repark, :corrupt_guidance}`: the durable consumed marker
      + reason make the re-park authoritative across further recoveries
      like every other repark lane — defense-in-depth for decryption
      failing AT RECOVERY TIME (vault key unavailable) even though the
      mint-time collapse grafts;
    * `{:ok, nil}` → `:none`.
  """
  @spec adopt_recovered_guidance(t(), {:ok, guidance_copy() | nil} | {:error, :corrupt_guidance}) ::
          {:none | :restored | :kept | {:repark, repark_reason()}, t()}
  def adopt_recovered_guidance(%__MODULE__{} = rs, {:ok, nil}), do: {:none, rs}

  def adopt_recovered_guidance(%__MODULE__{} = rs, {:ok, %{repark_reason: reason} = copy})
      when not is_nil(reason) do
    {{:repark, reason}, restore_guidance_copy(rs, copy)}
  end

  def adopt_recovered_guidance(%__MODULE__{} = rs, {:ok, %{status: :pending, text: text} = copy})
      when is_binary(text) do
    {:restored, restore_guidance_copy(rs, copy)}
  end

  def adopt_recovered_guidance(%__MODULE__{} = rs, {:ok, %{status: :pending} = copy}) do
    {{:repark, :guidance_text_missing}, consume_graft(rs, copy, :guidance_text_missing)}
  end

  def adopt_recovered_guidance(%__MODULE__{} = rs, {:ok, %{status: :inflight} = copy}) do
    {{:repark, :inflight_delivery_ambiguous},
     consume_graft(rs, copy, :inflight_delivery_ambiguous)}
  end

  def adopt_recovered_guidance(%__MODULE__{} = rs, {:ok, %{status: :consumed} = copy}) do
    {:kept, restore_guidance_copy(rs, copy)}
  end

  def adopt_recovered_guidance(%__MODULE__{} = rs, {:error, :corrupt_guidance}) do
    {{:repark, :corrupt_guidance},
     consume_graft(rs, %{status: :consumed, guidance_rev: rs.guidance_rev}, :corrupt_guidance)}
  end

  # Status/text/rev/reason restore; the state's own epoch/revision stand
  # (the recovered state was already stamped with the live incarnation).
  defp restore_guidance_copy(rs, copy) do
    %{
      rs
      | pending_guidance: %{status: copy.status, text: copy.text},
        guidance_rev: copy.guidance_rev,
        repark_reason: Map.get(copy, :repark_reason)
    }
  end

  # Graft at the copy's rev, then consume (rev+1) so the durable re-park
  # marker out-revs the stale copy it replaces; the reason makes it
  # authoritative across further recoveries.
  defp consume_graft(rs, copy, reason) do
    grafted = %{
      rs
      | pending_guidance: %{status: copy.status, text: nil},
        guidance_rev: copy.guidance_rev
    }

    %{guidance_consumed(grafted) | repark_reason: reason}
  end

  # ---- Per-turn mode resolution ----

  @doc """
  Resolves the vendor invocation mode for this turn: `:continuation`
  only for a trusted anchor in the same workdir; everything else is a
  fresh armed start with the reason attached (`:unanchored`,
  `:provisional`, `:poisoned`, `:cwd_mismatch`, `:no_workdir`).
  """
  @spec resolve_mode(t(), String.t() | nil) :: :continuation | {:fresh_armed, atom()}
  def resolve_mode(%__MODULE__{status: :anchored, workdir: wd} = _rs, cwd)
      when is_binary(wd) and wd == cwd,
      do: :continuation

  def resolve_mode(%__MODULE__{status: :anchored, workdir: wd}, cwd)
      when is_binary(wd) and is_binary(cwd),
      do: {:fresh_armed, :cwd_mismatch}

  def resolve_mode(%__MODULE__{status: :anchored}, _cwd), do: {:fresh_armed, :no_workdir}
  def resolve_mode(%__MODULE__{status: status}, _cwd), do: {:fresh_armed, status}

  @doc "Validates a vendor session/thread id as safe argv data."
  @spec valid_session_id?(term()) :: boolean()
  def valid_session_id?(id) when is_binary(id) do
    byte_size(id) in 1..@max_session_id_bytes and String.valid?(id) and
      not Regex.match?(~r/[\x00-\x1F\x7F]/, id)
  end

  def valid_session_id?(_), do: false

  # ---- Codecs ----

  @doc """
  The sanitized anchor-state wire map (string keys, no guidance text,
  no token — see the moduledoc). Identical shape in both stores.
  """
  @spec encode_state(t()) :: map()
  def encode_state(%__MODULE__{} = rs) do
    %{
      "v" => 1,
      "arming" => Atom.to_string(rs.arming),
      "ownership" => rs.ownership && Atom.to_string(rs.ownership),
      "status" => Atom.to_string(rs.status),
      "session_id" => rs.session_id,
      "workdir" => rs.workdir,
      "session_start_source" => Atom.to_string(rs.session_start_source),
      "retry_used" => rs.retry_used,
      "anchored_at" => rs.anchored_at && DateTime.to_iso8601(rs.anchored_at),
      "epoch" => rs.epoch,
      "revision" => rs.revision
    }
  end

  @doc """
  The metadata guidance marker — status + `guidance_rev` + epoch (+ the
  `repark_reason` when set), never text. `nil` when the state has never
  carried guidance. The checkpoint envelope (`encode_guidance/1`) builds
  on this marker, so the reason rides BOTH codecs.
  """
  @spec encode_guidance_marker(t()) :: map() | nil
  def encode_guidance_marker(%__MODULE__{pending_guidance: nil}), do: nil

  def encode_guidance_marker(%__MODULE__{pending_guidance: %{status: status}} = rs) do
    marker = %{
      "v" => 1,
      "status" => Atom.to_string(status),
      "guidance_rev" => rs.guidance_rev,
      "epoch" => rs.epoch
    }

    if rs.repark_reason,
      do: Map.put(marker, "repark_reason", Atom.to_string(rs.repark_reason)),
      else: marker
  end

  @doc """
  The checkpoint guidance object: the marker plus the Vault-encrypted
  text envelope. Strict — an encryption failure surfaces as an error so
  a checked save can refuse to ack, never persisting a silently
  text-less answer. `{:ok, nil}` when no guidance.
  """
  @spec encode_guidance(t()) :: {:ok, map() | nil} | {:error, term()}
  def encode_guidance(%__MODULE__{pending_guidance: nil}), do: {:ok, nil}

  def encode_guidance(%__MODULE__{pending_guidance: %{text: nil}} = rs),
    do: {:ok, encode_guidance_marker(rs)}

  def encode_guidance(%__MODULE__{pending_guidance: %{text: text}} = rs)
      when is_binary(text) do
    case Vault.encrypt(text) do
      {:ok, ciphertext} ->
        envelope = %{"v" => 1, "alg" => "vault", "data" => Base.encode64(ciphertext)}
        {:ok, Map.put(encode_guidance_marker(rs), "text", envelope)}

      {:error, reason} ->
        {:error, {:guidance_encrypt_failed, reason}}
    end
  end

  @doc """
  Whitelist decode of an anchor-state copy. `:error` on anything
  malformed — recovery treats a garbled copy as absent, never guesses.
  """
  @spec decode_state(term()) :: {:ok, t()} | :error
  def decode_state(%{"v" => 1} = map) when is_map(map) do
    with {:ok, arming} <- fetch_mapped(map, "arming", %{"off" => :off, "armed" => :armed}),
         {:ok, status} <- fetch_mapped(map, "status", @statuses),
         {:ok, ownership} <- fetch_optional_mapped(map, "ownership", @ownerships),
         {:ok, source} <- fetch_mapped(map, "session_start_source", @sources),
         {:ok, retry_used} <- fetch_boolean(map, "retry_used"),
         {:ok, epoch} <- fetch_non_neg(map, "epoch"),
         {:ok, revision} <- fetch_non_neg(map, "revision"),
         {:ok, session_id} <- fetch_session_id(map, status),
         {:ok, workdir} <- fetch_optional_binary(map, "workdir"),
         {:ok, anchored_at} <- fetch_optional_datetime(map, "anchored_at") do
      {:ok,
       %__MODULE__{
         arming: arming,
         ownership: ownership,
         status: status,
         session_id: session_id,
         workdir: workdir,
         session_start_source: source,
         retry_used: retry_used,
         anchored_at: anchored_at,
         epoch: epoch,
         revision: revision
       }}
    end
  end

  def decode_state(_), do: :error

  @doc """
  Whitelist decode of a guidance copy (either store's shape). Text is
  decrypted when the envelope is present; a corrupt envelope is a
  DISTINCT loud result — the caller re-parks, never resends, never
  silently drops. `{:ok, nil}` for an absent copy.
  """
  @spec decode_guidance(term()) :: {:ok, guidance_copy() | nil} | {:error, :corrupt_guidance}
  def decode_guidance(nil), do: {:ok, nil}

  def decode_guidance(%{"v" => 1} = map) when is_map(map) do
    with {:ok, status} <- fetch_mapped(map, "status", @guidance_statuses),
         {:ok, rev} <- fetch_non_neg(map, "guidance_rev"),
         {:ok, epoch} <- fetch_non_neg(map, "epoch") do
      case decode_guidance_text(Map.get(map, "text")) do
        {:ok, text} ->
          {:ok,
           %{
             status: status,
             guidance_rev: rev,
             epoch: epoch,
             text: text,
             repark_reason: decode_repark_reason(Map.get(map, "repark_reason"))
           }}

        {:error, :corrupt_guidance} ->
          {:error, :corrupt_guidance}
      end
    else
      :error -> {:error, :corrupt_guidance}
    end
  end

  def decode_guidance(_), do: {:error, :corrupt_guidance}

  @doc """
  Whitelist decode of a wire `repark_reason` string (public for the
  ForgeView `needs_input` projection). Non-fatal: an unknown reason drops
  to nil (the copy stays usable) rather than corrupting the whole copy,
  and `String.to_atom/1` never runs on wire data.
  """
  @spec decode_repark_reason(term()) :: repark_reason() | nil
  def decode_repark_reason(reason) when is_binary(reason), do: Map.get(@repark_reasons, reason)
  def decode_repark_reason(_), do: nil

  @doc """
  Merges the two stores' decoded copies into the recovered state.

  Anchor state: newest `{epoch, revision}` among the complete copies
  (both stores carry full anchor state). Guidance status: highest
  `guidance_rev` within the selected epoch — equal revs prefer the
  CHECKPOINT copy (the text carrier; one struct encodes both copies per
  checked save, so an equal-rev tie is the NORMAL state, and the
  metadata marker winning it would strip the text). Guidance text: only
  ever from the checkpoint copy, and only when the checkpoint copy is
  the status winner — a STRICTLY newer metadata marker without text
  still wins status and the text is honestly absent
  (pending-without-text re-parks). Returns `nil` when no state copy
  exists.
  """
  @spec select(t() | nil, guidance_copy() | nil, t() | nil, guidance_copy() | nil) :: t() | nil
  def select(md_state, md_guidance, cp_state, cp_guidance) do
    case Enum.reject([md_state, cp_state], &is_nil/1) do
      [] ->
        nil

      candidates ->
        anchor = Enum.max_by(candidates, &{&1.epoch, &1.revision})
        merge_guidance(anchor, md_guidance, cp_guidance)
    end
  end

  # ---- Private ----

  defp anchor(rs, session_id, workdir, ownership) do
    if valid_session_id?(session_id) do
      {:ok,
       %{
         rs
         | status: :anchored,
           ownership: ownership,
           session_id: session_id,
           workdir: workdir || rs.workdir,
           anchored_at: DateTime.utc_now(),
           retry_used: false
       }}
    else
      {:error, :invalid_session_id}
    end
  end

  # Checkpoint FIRST: `Enum.max_by` is first-maximal, so the equal-rev tie
  # (the normal checked-save state — one struct encoded both copies) resolves
  # to the text-carrying checkpoint copy; a strictly newer metadata marker
  # still wins. The winner's `repark_reason` rides the merge.
  defp merge_guidance(anchor, md_guidance, cp_guidance) do
    in_epoch = fn
      %{epoch: e} -> e == anchor.epoch
      _ -> false
    end

    candidates =
      Enum.filter(
        [{:checkpoint, cp_guidance}, {:metadata, md_guidance}],
        fn {_src, g} -> not is_nil(g) and in_epoch.(g) end
      )

    case candidates do
      [] ->
        %{anchor | pending_guidance: nil, guidance_rev: 0}

      _ ->
        {source, winner} = Enum.max_by(candidates, fn {_src, g} -> g.guidance_rev end)
        text = if source == :checkpoint, do: winner.text, else: nil

        %{
          anchor
          | pending_guidance: %{status: winner.status, text: text},
            guidance_rev: winner.guidance_rev,
            repark_reason: Map.get(winner, :repark_reason)
        }
    end
  end

  defp decode_guidance_text(nil), do: {:ok, nil}

  defp decode_guidance_text(%{"v" => 1, "alg" => "vault", "data" => b64}) when is_binary(b64) do
    with {:ok, ciphertext} <- Base.decode64(b64),
         {:ok, plaintext} when is_binary(plaintext) <- Vault.decrypt(ciphertext) do
      {:ok, plaintext}
    else
      _ -> {:error, :corrupt_guidance}
    end
  end

  defp decode_guidance_text(_), do: {:error, :corrupt_guidance}

  defp fetch_mapped(map, key, whitelist) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> Map.fetch(whitelist, value)
      _ -> :error
    end
  end

  defp fetch_optional_mapped(map, key, whitelist) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> Map.fetch(whitelist, value)
      _ -> :error
    end
  end

  defp fetch_boolean(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch_non_neg(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> :error
    end
  end

  # Cross-field: a live anchor requires a valid id; unanchored must not
  # carry one; a poisoned copy may keep the (recorded) poisoned id.
  defp fetch_session_id(map, status) do
    case {Map.get(map, "session_id"), status} do
      {nil, status} when status in [:unanchored, :poisoned] -> {:ok, nil}
      {id, status} when status in [:anchored, :provisional, :poisoned] -> validate_id(id)
      _ -> :error
    end
  end

  defp validate_id(id) do
    if valid_session_id?(id), do: {:ok, id}, else: :error
  end

  defp fetch_optional_binary(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch_optional_datetime(map, key) do
    case Map.get(map, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> {:ok, dt}
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
