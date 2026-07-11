defmodule JidoClaw.Web.GraphqlRouteTest do
  @moduledoc """
  Route-level integration for the `/gql` surface (argus P1) — catches the
  wiring the schema/plug unit tests can't: the `[:api, :api_auth, :graphql]`
  pipeline order, policy scoping through the Absinthe context, the read
  actions' limit contracts, the pinned complexity/token controls, and the
  guarded `/graphiql` mount (compiled in test exactly so these tests can
  prove the guard).

  `async: false`: boots the shared Endpoint and (for the 503 case) mutates
  the `:tenant_access_module` app env.
  """
  use JidoClaw.TenantCase, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias JidoClaw.Accounts.ApiKey
  alias JidoClaw.Accounts.User
  alias JidoClaw.Orchestration.WorkflowRun
  alias JidoClaw.Projects.Project
  alias JidoClaw.Tenants.Access

  @endpoint JidoClaw.Web.Endpoint

  @html_accept "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

  defmodule InfraDownAccess do
    @moduledoc false

    @spec ensure_active(String.t()) :: {:error, :db_down}
    def ensure_active(_tenant_id), do: {:error, :db_down}
  end

  setup do
    start_supervised!(JidoClaw.Web.Endpoint)
    previous_access = Application.fetch_env(:jido_claw, :tenant_access_module)

    on_exit(fn ->
      case previous_access do
        {:ok, value} -> Application.put_env(:jido_claw, :tenant_access_module, value)
        :error -> Application.delete_env(:jido_claw, :tenant_access_module)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp register_actor! do
    password = "valid-password-123456"

    {:ok, user} =
      User.register_with_password(
        %{
          email: "gql-#{System.unique_integer([:positive])}@example.com",
          password: password,
          password_confirmation: password
        },
        authorize?: false
      )

    {:ok, api_key} = ApiKey.create(user.id, authorize?: false)
    plaintext = Ash.Resource.get_metadata(api_key, :plaintext_api_key)
    tenant_id = to_string(user.id)

    # Run seeding happens before any gated request, so the tenant row the
    # create policy's ActorTenantActive check reads must already exist (the
    # gate's provision-on-first-request path is covered in its plug test).
    {:ok, _} = Tenant.ensure(tenant_id)

    %{user: user, key: plaintext, tenant_id: tenant_id, actor: actor_for(tenant_id)}
  end

  defp seed_project!(attrs) do
    Project.create!(
      Map.merge(
        %{
          name: "proj-#{System.unique_integer([:positive])}",
          github_full_name: "org/repo-#{System.unique_integer([:positive])}"
        },
        attrs
      ),
      authorize?: false
    )
  end

  defp seed_run!(%{tenant_id: tenant_id, actor: actor}, attrs) do
    WorkflowRun.create!(
      Map.merge(%{name: "run-#{System.unique_integer([:positive])}"}, attrs),
      tenant: tenant_id,
      actor: actor
    )
  end

  defp gql(key, query, variables \\ %{}) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      if key, do: put_req_header(conn, "x-api-key", key), else: conn
    end)
    |> post("/gql", Jason.encode!(%{query: query, variables: variables}))
  end

  defp gql_data(key, query, variables \\ %{}) do
    response = json_response(gql(key, query, variables), 200)
    refute Map.has_key?(response, "errors"), "unexpected errors: #{inspect(response["errors"])}"
    response["data"]
  end

  # ---------------------------------------------------------------------------
  # Auth + tenant gate wiring
  # ---------------------------------------------------------------------------

  test "POST /gql without a key is a 401 before any resolution" do
    conn = gql(nil, "{ projects { id } }")

    assert json_response(conn, 401) == %{"error" => "missing_api_key"}
  end

  test "a suspended tenant's valid key gets a 403 on a global-resource query" do
    %{key: key, tenant_id: tenant_id} = register_actor!()
    seed_project!(%{})

    :ok = Access.ensure_active(tenant_id)
    {:ok, tenant} = Tenant.by_id(tenant_id)
    {:ok, _} = Tenant.suspend(tenant)

    conn = gql(key, "{ projects { id name } }")

    assert json_response(conn, 403) == %{"error" => "tenant_inactive"}
  end

  test "a tenant-activity infra failure gets a 503, never data" do
    %{key: key} = register_actor!()
    Application.put_env(:jido_claw, :tenant_access_module, InfraDownAccess)

    conn = gql(key, "{ projects { id } }")

    assert json_response(conn, 503) == %{"error" => "tenant_unavailable"}
  end

  # ---------------------------------------------------------------------------
  # Projects
  # ---------------------------------------------------------------------------

  test "authed projects query returns seeded rows with allowlisted fields" do
    %{key: key} = register_actor!()
    project = seed_project!(%{name: "argus-projects-smoke"})

    data = gql_data(key, "{ projects { id name githubFullName defaultBranch } }")

    row = Enum.find(data["projects"], &(&1["id"] == project.id))
    assert row, "seeded project missing from projects query"
    assert row["name"] == "argus-projects-smoke"
    assert row["githubFullName"] == project.github_full_name
    assert row["defaultBranch"] == "main"
  end

  test "projects orders alphabetically with an id tie-break and honors limit" do
    %{key: key} = register_actor!()

    b = seed_project!(%{name: "argus-order-b"})
    a = seed_project!(%{name: "argus-order-a"})
    twin1 = seed_project!(%{name: "argus-order-twin"})
    twin2 = seed_project!(%{name: "argus-order-twin"})
    [twin_low, twin_high] = Enum.sort_by([twin1, twin2], & &1.id)

    data = gql_data(key, "{ projects { id name } }")
    ours = Enum.filter(data["projects"], &String.starts_with?(&1["name"], "argus-order-"))

    assert Enum.map(ours, & &1["id"]) == [a.id, b.id, twin_low.id, twin_high.id]

    limited = gql_data(key, "{ projects(limit: 1) { id } }")
    assert [_only] = limited["projects"]
  end

  test "projects limit outside 1..200 is an honest validation error" do
    %{key: key} = register_actor!()

    for bad <- [0, 201] do
      response = json_response(gql(key, "{ projects(limit: #{bad}) { id } }"), 200)

      assert [_ | _] = response["errors"], "expected a validation error for limit #{bad}"
      assert response["data"]["projects"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Workflow runs
  # ---------------------------------------------------------------------------

  test "recentWorkflowRuns is tenant-scoped (two tenants, positive rows asserted)" do
    mine = register_actor!()
    theirs = register_actor!()

    my_run = seed_run!(mine, %{name: "mine-scoped"})
    their_run = seed_run!(theirs, %{name: "theirs-scoped"})

    data = gql_data(mine.key, "{ recentWorkflowRuns { id name } }")
    ids = Enum.map(data["recentWorkflowRuns"], & &1["id"])

    assert my_run.id in ids
    refute their_run.id in ids
  end

  test "cross-tenant workflowRun(id:) resolves to nothing" do
    mine = register_actor!()
    theirs = register_actor!()
    their_run = seed_run!(theirs, %{})

    response =
      json_response(
        gql(mine.key, "query($id: ID!) { workflowRun(id: $id) { id } }", %{id: their_run.id}),
        200
      )

    assert response["data"]["workflowRun"] == nil
  end

  test "workflowRun resolves the nested project" do
    me = register_actor!()
    project = seed_project!(%{name: "argus-nested"})
    run = seed_run!(me, %{project_id: project.id})

    data =
      gql_data(
        me.key,
        "query($id: ID!) { workflowRun(id: $id) { id project { id name } } }",
        %{id: run.id}
      )

    assert data["workflowRun"]["project"] == %{"id" => project.id, "name" => "argus-nested"}
  end

  test "recentWorkflowRuns defaults to 50 newest and honors limit: 1" do
    me = register_actor!()
    [oldest | _rest] = for i <- 1..50, do: seed_run!(me, %{name: "bulk-#{i}"})
    newest = seed_run!(me, %{name: "bulk-newest"})

    data = gql_data(me.key, "{ recentWorkflowRuns { id } }")
    ids = Enum.map(data["recentWorkflowRuns"], & &1["id"])

    # 51 seeded, default page holds the newest 50 — the oldest falls off.
    assert Enum.count_until(ids, 51) == 50
    assert newest.id == hd(ids)
    refute oldest.id in ids

    limited = gql_data(me.key, "{ recentWorkflowRuns(limit: 1) { id } }")
    assert Enum.map(limited["recentWorkflowRuns"], & &1["id"]) == [newest.id]
  end

  test "equal inserted_at rows order deterministically by id desc" do
    me = register_actor!()
    run1 = seed_run!(me, %{name: "tie-1"})
    run2 = seed_run!(me, %{name: "tie-2"})

    tie = DateTime.utc_now()
    ids = [run1.id, run2.id]

    {2, _} =
      JidoClaw.Repo.update_all(from(r in WorkflowRun, where: r.id in ^ids),
        set: [inserted_at: tie]
      )

    data = gql_data(me.key, "{ recentWorkflowRuns { id } }")
    got = Enum.filter(Enum.map(data["recentWorkflowRuns"], & &1["id"]), &(&1 in ids))

    assert got == Enum.sort(ids, :desc)
  end

  test "recentWorkflowRuns limit outside 1..200 is an honest validation error" do
    me = register_actor!()

    for bad <- [0, 201] do
      response = json_response(gql(me.key, "{ recentWorkflowRuns(limit: #{bad}) { id } }"), 200)

      assert [_ | _] = response["errors"], "expected a validation error for limit #{bad}"
      assert response["data"]["recentWorkflowRuns"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Disposition surfacing (camus C1-4 through the shared Visibility seam)
  # ---------------------------------------------------------------------------

  test "a run whose result carries the disposition marker surfaces it; a plain run is null" do
    me = register_actor!()
    amber = seed_run!(me, %{name: "amber-run"})
    plain = seed_run!(me, %{name: "plain-run"})

    # Written with atom keys via the projection's private action; the JSONB
    # round-trip hands the calculation string keys — the shared Visibility
    # derivation must tolerate both (unit-pinned below).
    amber
    |> Ash.Changeset.for_update(
      :set_status,
      %{
        status: :completed,
        result: %{disposition: "route_done_with_findings", findings_deferred_count: 2}
      },
      tenant: me.tenant_id,
      authorize?: false
    )
    |> Ash.update!()

    data =
      gql_data(me.key, "{ recentWorkflowRuns { id status disposition findingsDeferredCount } }")

    rows = Map.new(data["recentWorkflowRuns"], &{&1["id"], &1})

    assert %{
             "status" => "COMPLETED",
             "disposition" => "route_done_with_findings",
             "findingsDeferredCount" => 2
           } = rows[amber.id]

    assert %{"disposition" => nil, "findingsDeferredCount" => nil} = rows[plain.id]
  end

  test "the calculations derive from atom-keyed results too (pre-JSONB shape)" do
    alias JidoClaw.Orchestration.WorkflowRun.Calculations.Disposition
    alias JidoClaw.Orchestration.WorkflowRun.Calculations.FindingsDeferredCount

    records = [
      %WorkflowRun{
        result: %{disposition: "route_done_with_findings", findings_deferred_count: 1}
      },
      %WorkflowRun{result: %{"disposition" => "verify_failed", "findings_deferred_count" => 3}},
      %WorkflowRun{result: nil}
    ]

    assert Disposition.calculate(records, %{}, nil) ==
             ["route_done_with_findings", "verify_failed", nil]

    assert FindingsDeferredCount.calculate(records, %{}, nil) == [1, 3, nil]
  end

  # ---------------------------------------------------------------------------
  # Complexity / token controls (pinned on the /gql forward)
  # ---------------------------------------------------------------------------

  test "a query above max_complexity 200 is rejected without resolving" do
    %{key: key} = register_actor!()

    fields = "id name githubFullName defaultBranch insertedAt updatedAt"
    blocks = Enum.map_join(0..29, " ", fn i -> "p#{i}: projects { #{fields} }" end)

    response = json_response(gql(key, "{ #{blocks} }"), 200)

    assert [_ | _] = response["errors"]
    assert Enum.any?(response["errors"], &(&1["message"] =~ "complex"))
    refute response["data"]
  end

  test "a document above token_limit 5000 is rejected at parse" do
    %{key: key} = register_actor!()

    aliases = Enum.map_join(1..2500, " ", fn i -> "a#{i}: __typename" end)

    response = json_response(gql(key, "{ #{aliases} }"), 200)

    assert [%{"message" => message} | _] = response["errors"]
    assert message =~ "Token limit exceeded"
    refute response["data"]
  end

  # ---------------------------------------------------------------------------
  # Transport batching (rejected — the limits above are per batch ELEMENT, so
  # a batch's aggregate cost would be unbounded; see GraphqlBatchGuard)
  # ---------------------------------------------------------------------------

  test "a JSON array body (transport batch) is rejected 400 before execution" do
    %{key: key} = register_actor!()

    batch = List.duplicate(%{query: "{ projects { id } }"}, 3)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-api-key", key)
      |> post("/gql", Jason.encode!(batch))

    assert json_response(conn, 400) == %{"error" => "batching_not_supported"}
  end

  test "an operations query param (the params batch vector) is rejected 400" do
    %{key: key} = register_actor!()

    operations = Jason.encode!(List.duplicate(%{query: "{ projects { id } }"}, 2))

    conn =
      build_conn()
      |> put_req_header("x-api-key", key)
      |> get("/gql?" <> URI.encode_query(%{"operations" => operations}))

    assert json_response(conn, 400) == %{"error" => "batching_not_supported"}
  end

  # ---------------------------------------------------------------------------
  # GraphiQL guard wiring (route exists in test env exactly for these)
  # ---------------------------------------------------------------------------

  test "an unauthenticated JSON POST to /graphiql is halted with no data" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> post("/graphiql", Jason.encode!(%{query: "{ __schema { queryType { name } } }"}))

    assert response(conn, 404) == "Not Found"
  end

  test "an HTML GET /graphiql?query= is halted before execution (introspection probe)" do
    conn =
      build_conn()
      |> put_req_header("accept", @html_accept)
      |> get("/graphiql?query={__schema{queryType{name}}}")

    # Introspection chosen so an actor-less empty-list result can't
    # false-pass: were the document executed, the body would carry the
    # query-type name regardless of auth.
    assert response(conn, 404) == "Not Found"
    refute conn.resp_body =~ "RootQueryType"
  end

  test "a plain HTML GET /graphiql renders the playground UI" do
    conn =
      build_conn()
      |> put_req_header("accept", @html_accept)
      |> get("/graphiql")

    assert html_response(conn, 200) =~ "GraphiQL Playground"
  end
end
