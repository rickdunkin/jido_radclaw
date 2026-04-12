defmodule JidoClaw.Web.Layouts do
  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]
  import JidoClaw.Web.CoreComponents

  embed_templates("layouts/*")
end
