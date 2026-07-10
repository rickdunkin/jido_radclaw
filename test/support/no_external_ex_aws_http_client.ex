defmodule JidoClaw.Test.NoExternalExAwsHttpClient do
  @moduledoc """
  Test-only ExAws transport that makes every attempted network request fail
  locally. Combined with static test credentials, this prevents both AWS
  instance-metadata discovery and accidental S3 traffic.
  """

  @behaviour ExAws.Request.HttpClient

  @impl ExAws.Request.HttpClient
  def request(_method, _url, _body, _headers, _http_opts) do
    {:error, %{reason: :external_network_disabled_in_test}}
  end
end
