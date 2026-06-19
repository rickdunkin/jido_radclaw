defmodule JidoClaw.RouteComposer.CatalogValidatorTest do
  use ExUnit.Case, async: true

  import JidoClaw.RouteComposer.TestFixtures

  alias JidoClaw.RouteComposer.Catalog
  alias JidoClaw.RouteComposer.CatalogValidator
  alias JidoClaw.RouteComposer.Stage
  alias JidoClaw.RouteComposer.TestFixtures

  @coherence_cases [
    %{
      name: "bad routes are flagged",
      opts: [
        name: "s",
        unit: {:seed, "s"},
        routes: ["bogus"],
        sub: ["request-received"],
        pub: ["scope-shift"]
      ],
      contains: "not a subset"
    },
    %{
      name: "empty routes are flagged",
      opts: [
        name: "s",
        unit: {:seed, "s"},
        routes: [],
        sub: ["request-received"],
        pub: ["scope-shift"]
      ],
      contains: "missing `routes`"
    },
    %{
      name: "a missing scope-shift is flagged",
      opts: [
        name: "s",
        unit: {:seed, "s"},
        routes: ["code"],
        sub: ["request-received"],
        pub: ["foo"]
      ],
      contains: "scope-shift"
    },
    %{
      name: "an unsatisfiable required input is flagged",
      opts: [
        name: "s",
        unit: {:worker_template, "coder"},
        routes: ["code"],
        req: ["ghost-art"],
        sub: ["request-received"],
        pub: ["scope-shift"],
        task: "t"
      ],
      contains: "ghost-art"
    },
    %{
      name: "an orphan subscribe is flagged",
      opts: [
        name: "s",
        unit: {:seed, "s"},
        routes: ["code"],
        sub: ["ghost-sig"],
        pub: ["scope-shift"]
      ],
      contains: "ghost-sig"
    },
    %{
      name: "an orphan lock while is flagged",
      opts: [
        name: "impl",
        unit: {:worker_template, "coder"},
        routes: ["code"],
        out: ["diff"],
        sub: ["request-received"],
        pub: ["tests-ready", "scope-shift"],
        lock: [%{while: "ghost-signal", until: "tests-ready"}]
      ],
      contains: "ghost-signal"
    },
    %{
      name: "an orphan lock until is flagged",
      opts: [
        name: "impl",
        unit: {:worker_template, "coder"},
        routes: ["code"],
        out: ["diff"],
        sub: ["request-received"],
        pub: ["needs-tests", "scope-shift"],
        lock: [%{while: "needs-tests", until: "phantom-done"}]
      ],
      contains: "phantom-done"
    },
    %{
      name: "a worker stage with a required input but empty task is flagged",
      opts: [
        name: "impl",
        unit: {:worker_template, "coder"},
        routes: ["code"],
        req: ["request"],
        out: ["diff"],
        sub: ["request-received"],
        pub: ["scope-shift"]
      ],
      contains: "task"
    },
    %{
      name: "a self-dependency is flagged",
      opts: [
        name: "s",
        unit: {:worker_template, "coder"},
        routes: ["code"],
        req: ["diff"],
        out: ["diff"],
        sub: ["request-received"],
        pub: ["scope-shift"],
        task: "t"
      ],
      contains: "self-dependency"
    }
  ]

  @structural_cases [
    %{
      name: "a name not matching its key is flagged",
      key: "a",
      stage: %Stage{
        name: "b",
        unit: {:seed, "a"},
        routes: ["code"],
        input: %{required: [], optional: []},
        output: [],
        subscribes: ["request-received"],
        publishes: ["scope-shift"],
        lock: []
      },
      contains: "does not match catalog key"
    },
    %{
      name: "a non-list field is flagged",
      key: "a",
      stage: %Stage{
        name: "a",
        unit: {:seed, "a"},
        routes: "code",
        input: %{required: [], optional: []},
        output: [],
        subscribes: ["request-received"],
        publishes: ["scope-shift"],
        lock: []
      },
      contains: "routes"
    },
    %{
      name: "a bad input shape is flagged",
      key: "a",
      stage: %Stage{
        name: "a",
        unit: {:seed, "a"},
        routes: ["code"],
        input: %{required: "x"},
        output: [],
        subscribes: ["request-received"],
        publishes: ["scope-shift"],
        lock: []
      },
      contains: "input"
    },
    %{
      name: "a bad lock shape is flagged",
      key: "a",
      stage: %Stage{
        name: "a",
        unit: {:seed, "a"},
        routes: ["code"],
        input: %{required: [], optional: []},
        output: [],
        subscribes: ["request-received"],
        publishes: ["scope-shift"],
        lock: [%{while: "a"}]
      },
      contains: "lock"
    },
    %{
      name: "an unknown unit tag is flagged",
      key: "a",
      stage: %Stage{
        name: "a",
        unit: {:bogus, "x"},
        routes: ["code"],
        input: %{required: [], optional: []},
        output: [],
        subscribes: ["request-received"],
        publishes: ["scope-shift"],
        lock: []
      },
      contains: "unit"
    }
  ]

  @typed_field_cases [
    %{name: "bad guard", opts: [guard: :nope], contains: "guard"},
    %{name: "bad model", opts: [model: "fast"], contains: "model"},
    %{name: "bad effort", opts: [effort: 5], contains: "effort"},
    %{name: "bad emit", opts: [emit: :wrong], contains: "emit"},
    %{name: "non-string task", opts: [task: 123], contains: "task"},
    %{name: "non-string lens", opts: [lens: :security], contains: "lens"}
  ]

  test "the starter catalog validates clean" do
    assert CatalogValidator.validate(Catalog.all()) == []
  end

  for row <- @coherence_cases do
    test "coherence: #{row.name}" do
      row = unquote(Macro.escape(row))
      cat = %{Keyword.fetch!(row.opts, :name) => TestFixtures.stage(row.opts)}
      assert Enum.any?(CatalogValidator.validate(cat), &String.contains?(&1, row.contains))
    end
  end

  for row <- @structural_cases do
    test "structural: #{row.name}" do
      row = unquote(Macro.escape(row))

      assert Enum.any?(
               CatalogValidator.validate(%{row.key => row.stage}),
               &String.contains?(&1, row.contains)
             )
    end
  end

  for row <- @typed_field_cases do
    test "structural typed field: #{row.name}" do
      row = unquote(Macro.escape(row))

      base = [
        name: "s",
        unit: {:seed, "s"},
        routes: ["code"],
        sub: ["request-received"],
        pub: ["scope-shift"]
      ]

      cat = %{"s" => TestFixtures.stage(Keyword.merge(base, row.opts))}
      assert Enum.any?(CatalogValidator.validate(cat), &String.contains?(&1, row.contains))
    end
  end

  test "an atom catalog key is flagged" do
    cat = %{
      a:
        stage(
          name: :a,
          unit: {:seed, "a"},
          routes: ["code"],
          sub: ["request-received"],
          pub: ["scope-shift"]
        )
    }

    assert Enum.any?(CatalogValidator.validate(cat), &String.contains?(&1, "catalog key"))
  end

  test "a non-binary key with another malformed field returns rather than crashes" do
    cat = %{{:weird} => stage(name: {:weird}, routes: "notalist")}

    assert Enum.any?(CatalogValidator.validate(cat), &String.contains?(&1, "catalog key"))
  end

  test "a non-%Stage{} catalog value returns rather than crashes" do
    assert Enum.any?(
             CatalogValidator.validate(%{"a" => %{not: "a stage"}}),
             &String.contains?(&1, "Stage")
           )
  end

  test "valid non-default scalar fields pass validation" do
    cat = %{
      "s" =>
        stage(
          name: "s",
          unit: {:worker_template, "coder"},
          routes: ["code"],
          req: ["request"],
          out: ["diff"],
          sub: ["request-received"],
          pub: ["scope-shift"],
          task: "do the thing",
          lens: "security",
          guard: :sticky,
          model: :capable,
          effort: :high,
          emit: {:mapper, "x"}
        )
    }

    assert CatalogValidator.validate(cat) == []
  end

  defp lens_stage(pubs) do
    %{
      "qr" =>
        stage(
          name: "qr",
          unit: {:worker_template, "reviewer"},
          lens: "quality",
          emit: :default,
          routes: ["code"],
          req: ["request"],
          out: ["findings"],
          sub: ["request-received"],
          pub: pubs,
          task: "review"
        )
    }
  end

  describe "emit :default + lens verdict-publishes hardening (invariant 8)" do
    test "a missing clean:<lens> is flagged at load" do
      problems = CatalogValidator.validate(lens_stage(["findings:quality", "scope-shift"]))
      assert Enum.any?(problems, &String.contains?(&1, "clean:quality"))
    end

    test "a missing findings:<lens> is flagged at load" do
      problems = CatalogValidator.validate(lens_stage(["clean:quality", "scope-shift"]))
      assert Enum.any?(problems, &String.contains?(&1, "findings:quality"))
    end

    test "declaring both verdict families passes" do
      assert CatalogValidator.validate(
               lens_stage(["clean:quality", "findings:quality", "scope-shift"])
             ) == []
    end

    test "a non-:default lens stage is exempt (the mapper isn't the default derivation)" do
      cat = %{
        "qr" =>
          stage(
            name: "qr",
            unit: {:worker_template, "reviewer"},
            lens: "quality",
            emit: {:mapper, "custom"},
            routes: ["code"],
            req: ["request"],
            out: ["findings"],
            sub: ["request-received"],
            pub: ["scope-shift"],
            task: "review"
          )
      }

      assert CatalogValidator.validate(cat) == []
    end
  end

  test "a data-graph cycle is flagged" do
    cat = %{
      "a" =>
        stage(
          name: "a",
          unit: {:worker_template, "coder"},
          routes: ["code"],
          req: ["y"],
          out: ["x"],
          sub: ["request-received"],
          pub: ["scope-shift"],
          task: "t"
        ),
      "b" =>
        stage(
          name: "b",
          unit: {:worker_template, "coder"},
          routes: ["code"],
          req: ["x"],
          out: ["y"],
          sub: ["request-received"],
          pub: ["scope-shift"],
          task: "t"
        )
    }

    assert Enum.any?(CatalogValidator.validate(cat), &String.contains?(&1, "cycle"))
  end

  test "a structural problem short-circuits the coherence checks" do
    stage = %Stage{
      name: "a",
      unit: {:seed, "a"},
      routes: ["code"],
      input: %{required: "x"},
      output: [],
      subscribes: ["request-received"],
      publishes: [],
      lock: []
    }

    problems = CatalogValidator.validate(%{"a" => stage})
    assert Enum.any?(problems, &String.contains?(&1, "input"))
    refute Enum.any?(problems, &String.contains?(&1, "scope-shift"))
  end

  test "family_match?/2 is bidirectional, unlike the router's one-directional matcher" do
    assert CatalogValidator.family_match?("findings", ["findings:security"])
    assert CatalogValidator.family_match?("findings:security", ["findings"])
    assert CatalogValidator.family_match?("findings", ["findings"])
    refute CatalogValidator.family_match?("findings", ["other"])

    qualified = %{
      "q" =>
        stage(
          name: "q",
          unit: {:worker_template, "coder"},
          routes: ["code"],
          sub: ["findings:security"],
          pub: ["scope-shift"]
        )
    }

    refute "q" in compose(qualified, ["code", "findings"]).route

    base = %{
      "b" =>
        stage(
          name: "b",
          unit: {:worker_template, "coder"},
          routes: ["code"],
          sub: ["findings"],
          pub: ["scope-shift"]
        )
    }

    assert "b" in compose(base, ["code", "findings:security"]).route
  end
end
