# The priv path here is a COMPILE-TIME source-tree read (@external_resource +
# File.read! while compiling from the checkout) — Application.app_dir points
# at a _build priv dir that need not exist when this file compiles, and the
# whole point of the module is that the RUNTIME artifact (the escript) has no
# priv at all: the accessors serve the embedded copies, never a path.
# credo:disable-for-this-file ExSlop.Check.Warning.PathExpandPriv
defmodule JidoClaw.Core.ThirdPartyLicenses do
  @moduledoc """
  Compile-time-embedded third-party license texts for artifacts that do NOT
  bundle `priv/` — today that is the escript (`escript/0` in mix.exs has no
  `include_priv_for`, and adding one would drag the built SPA and resource
  snapshots into the CLI binary). Source checkouts, Mix releases, and the
  Docker image all carry `priv/licenses/` directly; this module is the
  escript recipient's route (surfaced by the pre-boot
  `jidoclaw --third-party-licenses` flag in `JidoClaw.CLI.Main`).

  The embedded copies are byte-equal to the `priv/licenses/` files by
  construction (`@external_resource` + `File.read!` at compile time) and the
  equality is pinned by test — the served artifact can never silently drift
  from the committed license bytes, which are themselves pinned byte-equal
  to `deps/jido_action/LICENSE`.
  """

  @licenses_dir Path.expand("../../../priv/licenses", __DIR__)

  @jido_action_license_path Path.join(@licenses_dir, "jido_action-APACHE-2.0.txt")
  @jido_action_notice_path Path.join(@licenses_dir, "jido_action-NOTICE.txt")

  @external_resource @jido_action_license_path
  @external_resource @jido_action_notice_path

  @jido_action_license File.read!(@jido_action_license_path)
  @jido_action_notice File.read!(@jido_action_notice_path)

  @doc """
  The unmodified jido_action Apache-2.0 license text (Apache-2.0 §4(a)),
  byte-equal to `priv/licenses/jido_action-APACHE-2.0.txt`.
  """
  @spec jido_action_license() :: String.t()
  def jido_action_license, do: @jido_action_license

  @doc """
  The jido_action modification notice (Apache-2.0 §4(b)) for the forked
  `Jido.Exec` build, byte-equal to `priv/licenses/jido_action-NOTICE.txt`.
  """
  @spec jido_action_notice() :: String.t()
  def jido_action_notice, do: @jido_action_notice
end
