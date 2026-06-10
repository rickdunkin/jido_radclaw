defmodule JidoClaw.Web.ErrorJSON do
  @moduledoc "JSON error responses for the Phoenix endpoint."

  @spec render(String.t(), map()) :: %{error: map()}
  def render("404.json", _assigns) do
    %{error: %{status: 404, message: "Not Found"}}
  end

  def render("500.json", _assigns) do
    %{error: %{status: 500, message: "Internal Server Error"}}
  end

  def render(template, _assigns) do
    %{error: %{message: Phoenix.Controller.status_message_from_template(template)}}
  end
end
