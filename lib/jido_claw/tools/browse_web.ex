defmodule JidoClaw.Tools.BrowseWeb do
  use Jido.Action,
    name: "browse_web",
    description:
      "Fetch and read web pages using a headless browser. Supports content extraction, screenshot capture, and link extraction.",
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

  @max_content_bytes 10_240

  @impl true
  def run(%{url: url} = params, _context) do
    action = Map.get(params, :action, "get_content")
    do_browse(url, action)
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
  rescue
    e in UndefinedFunctionError ->
      {:error,
       "browser not available: #{Exception.message(e)}. Install the browser driver with: mix jido_browser.install vibium"}

    e ->
      {:error, "browser error: #{Exception.message(e)}"}
  end

  defp execute(session, url, action) do
    with {:ok, session, _nav} <- Jido.Browser.navigate(session, url) do
      case action do
        "get_content" ->
          get_content(session, url)

        "extract_links" ->
          extract_links(session, url)

        "screenshot" ->
          take_screenshot(session, url)

        other ->
          {:error,
           "unknown action #{inspect(other)}. Valid: get_content, extract_links, screenshot"}
      end
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
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
