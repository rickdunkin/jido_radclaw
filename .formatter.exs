[
  import_deps: [
    :ash,
    :ash_admin,
    :ash_archival,
    :ash_authentication,
    :ash_authentication_phoenix,
    :ash_cloak,
    :ash_json_api,
    :ash_paper_trail,
    :ash_phoenix,
    :ash_postgres,
    :ash_state_machine,
    :ecto,
    :ecto_sql,
    :phoenix,
    :reactor
  ],
  plugins: [Phoenix.LiveView.HTMLFormatter, Spark.Formatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs,heex}"
  ]
]
