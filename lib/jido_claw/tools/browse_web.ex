defmodule JidoClaw.Tools.BrowseWeb do
  @moduledoc false
  use JidoClaw.Tools.Action,
    name: "browse_web",
    description:
      "Fetch and read web pages using a headless browser. Supports content extraction, screenshot capture, and link extraction.",
    category: "browser",
    tags: ["browser", "read"],
    output_schema: [
      url: [type: :string, required: true],
      action: [type: :string, required: true],
      content: [type: :string],
      truncated: [type: :boolean],
      links: [type: {:list, :map}],
      count: [type: :integer],
      format: [type: :string],
      base64: [type: :string],
      size_bytes: [type: :integer],
      raw: [type: :string]
    ],
    schema: [
      url: [
        type: :string,
        required: true,
        doc: "URL to fetch (must include scheme, e.g. https://)"
      ],
      action: [
        type: :string,
        default: "get_content",
        doc: "What to do: get_content (default), extract_links, screenshot"
      ]
    ]

  alias JidoClaw.Security.DestinationPolicy

  @max_content_bytes 10_240

  @impl Jido.Action
  def run(%{url: url} = params, _context) do
    action = Map.get(params, :action, "get_content")

    # Deny internal destinations before the browser session even starts; the
    # {:error, reason} short-circuits through the shared pipeline.
    with :ok <- DestinationPolicy.check(url) do
      do_browse(url, action)
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp do_browse(url, action) do
    case Jido.Browser.start_session() do
      {:ok, session} ->
        result = execute(session, url, action)
        Jido.Browser.end_session(session)
        result

      {:error, reason} ->
        degraded_error(reason)
    end

    # Tool entry point: browser-driver faults (missing binary, runtime crash)
    # surface as `{:error, _}` to the LLM rather than escape as exceptions.
  rescue
    e in UndefinedFunctionError ->
      {:error,
       "browser not available: #{Exception.message(e)}. Install the browser driver with: mix jido_browser.install vibium"}

    # reach:disable-next-line bare_rescue
    e ->
      {:error, "browser error: #{Exception.message(e)}"}
  end

  defp execute(session, url, action) do
    case Jido.Browser.navigate(session, url) do
      {:ok, session, nav} -> recheck_destination(session, nav, url, action)
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  # The page can redirect (or JS-navigate) away from the vetted URL before we
  # read anything, so re-check the final destination — otherwise internal-host
  # content gets quoted into the transcript. The re-check is unconditional: a
  # final URL string-equal to the requested one is still re-resolved, because
  # DNS rebinding never changes the URL string — the same-string case is the
  # attack case, not a safe fast path. Redirect *detection* stays
  # adapter-dependent: prefer the live browser URL, fall back to navigate
  # metadata; Vibium and the Web CLI echo the requested URL there, so adapters
  # supporting neither get_url/evaluate nor real final-URL metadata degrade to
  # re-checking the requested URL — rebinds still caught, true redirects
  # missed. The internal *request* already happened out-of-process — what this
  # blocks is leaking the response, at the cost of one extra DNS resolution per
  # hostname browse. JS/meta-refresh navigation after this window remains out
  # of reach.
  defp recheck_destination(session, nav, url, action) do
    with :ok <- recheck(final_url(session, nav, url), url) do
      dispatch_action(action, session, url)
    end
  end

  defp recheck(final, requested) do
    case DestinationPolicy.check(final) do
      :ok -> :ok
      {:error, reason} -> {:error, recheck_denial(final, requested, reason)}
    end
  end

  defp recheck_denial(url, url, reason),
    do: "destination failed the post-navigation re-check: #{reason}"

  defp recheck_denial(_final, _requested, reason),
    do: "page redirected to a blocked destination: #{reason}"

  # Total over every adapter result shape — a broken URL probe must never turn
  # allowed browsing into a hard failure.
  defp final_url(session, nav, url) do
    live_url(session) || extract_url(nav) || url
  end

  defp live_url(session) do
    case Jido.Browser.get_url(session) do
      {:ok, _session, meta} -> extract_url(meta)
      _ -> nil
    end
  end

  # The adapter command path may be string-keyed; the JS fallback and nav
  # metadata from Vibium are atom-keyed. Normalize the shapes here, at the
  # boundary.
  defp extract_url(%{url: url}) when is_binary(url), do: url
  defp extract_url(%{"url" => url}) when is_binary(url), do: url
  defp extract_url(_other), do: nil

  defp dispatch_action("get_content", session, url), do: get_content(session, url)
  defp dispatch_action("extract_links", session, url), do: extract_links(session, url)
  defp dispatch_action("screenshot", session, url), do: take_screenshot(session, url)

  defp dispatch_action(other, _session, _url) do
    {:error, "unknown action #{inspect(other)}. Valid: get_content, extract_links, screenshot"}
  end

  defp get_content(session, url) do
    case Jido.Browser.extract_content(session, format: :markdown) do
      {:ok, _session, %{content: content}} ->
        truncated = truncate(content)

        {:ok,
         %{
           url: url,
           action: "get_content",
           content: truncated,
           truncated: byte_size(content) > @max_content_bytes
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp extract_links(session, url) do
    # Evaluate JS to collect all anchor hrefs from the page
    js = """
    Array.from(document.querySelectorAll('a[href]'))
      .map(a => ({text: a.textContent.trim().slice(0, 100), href: a.href}))
      .filter(l => l.href.startsWith('http'))
      .slice(0, 100)
    """

    case Jido.Browser.evaluate(session, js) do
      {:ok, _session, %{result: links}} when is_list(links) ->
        {:ok, %{url: url, action: "extract_links", links: links, count: length(links)}}

      {:ok, _session, result} ->
        {:ok, %{url: url, action: "extract_links", links: [], raw: inspect(result)}}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp take_screenshot(session, url) do
    case Jido.Browser.screenshot(session) do
      {:ok, _session, %{bytes: bytes}} ->
        encoded = Base.encode64(bytes)

        {:ok,
         %{
           url: url,
           action: "screenshot",
           format: "png",
           base64: encoded,
           size_bytes: byte_size(bytes)
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp truncate(content) when byte_size(content) <= @max_content_bytes, do: content

  defp truncate(content),
    do: binary_part(content, 0, @max_content_bytes) <> "\n\n[... truncated at 10KB ...]"

  defp format_error(%{message: msg}), do: msg
  defp format_error(%{reason: reason}), do: inspect(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp degraded_error(reason) do
    msg = format_error(reason)

    if String.contains?(msg, ["not found", "enoent", "executable", "binary", "vibium", "clicker"]) do
      {:error, "browser not available: #{msg}. Install with: mix jido_browser.install vibium"}
    else
      {:error, "browser session failed: #{msg}"}
    end
  end
end
