defmodule JidoClaw.Tools.SearchWeb do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "search_web",
    description:
      "Search the web via Brave Search and return ranked results (title, URL, snippet). " <>
        "Use to discover pages or docs when you don't already have a URL; follow up with browse_web to read one.",
    category: "browser",
    tags: ["browser", "web", "search"],
    output_schema: [
      query: [type: :string, required: true],
      results: [type: {:list, :map}, required: true],
      count: [type: :integer, required: true]
    ],
    schema: [
      query: [type: :string, required: true, doc: "Search query"],
      max_results: [
        type: :pos_integer,
        default: 10,
        doc: "Max results to return (1–20; upper bound capped by the backend)"
      ],
      country: [type: :string, default: "us", doc: "Country code (e.g. us, gb, de)"],
      search_lang: [type: :string, default: "en", doc: "Language code"],
      freshness: [
        type: :string,
        doc: "Recency filter: pd (24h), pw (week), pm (month), py (year)"
      ]
    ]

  alias JidoClaw.Tools.OutputRedaction

  @default_backend Jido.Browser.Actions.SearchWeb

  @impl Jido.Action
  def run(params, context) do
    # Outbound leakage hygiene: the shared wrapper only redacts the *result*, so
    # scrub the whole outbound param map here before it leaves the platform for
    # Brave — the exact MCP-proxy precedent (mcp/proxy_generator.ex) and the same
    # posture as the embedding pre-redact. Scrubbing every string field (not just
    # :query) closes the gap that query/country/search_lang/freshness are all
    # plain strings in this schema. redact/1 preserves atom keys and leaves the
    # integer max_results untouched, so the dep reads the scrubbed map normally.
    scrubbed = OutputRedaction.redact(params)
    backend().run(scrubbed, context)
  end

  # Swappable backend mirrors the `:jido_browser, :adapter` seam (browse_web_test)
  # and the `voyage_module:` injection (retrieval_test). Production always uses the
  # real Brave action; tests inject a stub.
  defp backend, do: Application.get_env(:jido_claw, :search_web_backend, @default_backend)
end
