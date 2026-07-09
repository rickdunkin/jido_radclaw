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

  describe "per-stage executor override (item 7 PR-4)" do
    defp executor_stage(opts) do
      stage(
        Keyword.merge(
          [
            name: "s",
            unit: {:worker_template, "coder"},
            routes: ["code"],
            sub: ["request-received"],
            pub: ["scope-shift"],
            task: "t"
          ],
          opts
        )
      )
    end

    test "every closed executor term is accepted on a worker stage" do
      for executor <- [
            :in_process,
            {:forge, :fake},
            {:forge, :shell},
            {:forge, :codex},
            {:forge, :claude_code},
            {:forge, :custom}
          ] do
        assert CatalogValidator.validate(%{"s" => executor_stage(executor: executor)}) == []
      end
    end

    test "an invalid executor term is rejected" do
      for executor <- [:codex, "in_process", {:forge, :bogus}, {:in_process}] do
        problems = CatalogValidator.validate(%{"s" => executor_stage(executor: executor)})
        assert Enum.any?(problems, &String.contains?(&1, "`executor` must be nil or one of"))
      end
    end

    test "a non-worker stage carrying an executor override is rejected at load" do
      non_worker = [
        executor_stage(unit: {:seed, "s"}, executor: :in_process, task: nil),
        executor_stage(unit: {:gate, "plan"}, executor: {:forge, :fake}, task: nil),
        executor_stage(
          unit: {:verify, "default"},
          executor: {:forge, :fake},
          task: nil,
          lens: "verify",
          pub: ["clean:verify", "findings:verify", "scope-shift"]
        )
      ]

      for bad_stage <- non_worker do
        problems = CatalogValidator.validate(%{"s" => bad_stage})

        assert Enum.any?(
                 problems,
                 &String.contains?(&1, "only valid on a {:worker_template, _} stage")
               )
      end
    end
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

  # AR-8c invariant 9: a reverse_verify stage must carry a lens + EXACTLY one
  # required input (the rerun helper reads only the first required artifact).
  defp reverse_verify_stage(opts) do
    %{
      "rv" =>
        stage(
          name: "rv",
          unit: {:worker_template, "system_verifier"},
          lens: Keyword.get(opts, :lens, "system"),
          reverse_verify: true,
          emit: :default,
          routes: ["system"],
          req: Keyword.get(opts, :req, ["request"]),
          out: ["findings"],
          sub: ["request-received"],
          pub: ["clean:system", "findings:system", "scope-shift"],
          task: "verify"
        )
    }
  end

  describe "reverse_verify invariant (invariant 9)" do
    test "a lens + exactly-one-required reverse_verify stage passes" do
      assert CatalogValidator.validate(reverse_verify_stage(req: ["request"])) == []
    end

    test "a reverse_verify stage with no lens is flagged" do
      problems = CatalogValidator.validate(reverse_verify_stage(lens: nil))
      assert Enum.any?(problems, &String.contains?(&1, "lens"))
    end

    test "a reverse_verify stage with two required inputs is flagged" do
      # Two seed artifacts so only the reverse_verify count invariant fires (not a
      # no-producer error on an unbacked second input).
      cat = reverse_verify_stage(req: ["request", "request"])
      problems = CatalogValidator.validate(cat)
      assert Enum.any?(problems, &String.contains?(&1, "exactly one required input"))
    end

    test "a reverse_verify stage with zero required inputs is flagged" do
      problems = CatalogValidator.validate(reverse_verify_stage(req: []))
      assert Enum.any?(problems, &String.contains?(&1, "exactly one required input"))
    end

    test "reverse_verify must be a boolean (structural group 0)" do
      bad = %{"rv" => %{reverse_verify_stage([])["rv"] | reverse_verify: "yes"}}
      problems = CatalogValidator.validate(bad)
      assert Enum.any?(problems, &String.contains?(&1, "reverse_verify"))
    end
  end

  # Item 5 invariant 10: the composer retains a SINGLE verify certificate
  # (`verified_integrity`, latest wins), so a second `{:verify, _}` stage in a
  # different Kahn level would ping-pong retract/re-verify at convergence until
  # the rerun budget terminalizes. Rejected at load; multi-check needs are
  # served by one stage's named `checks:` registry.
  describe "verify-unit invariants (invariant 10)" do
    test "the single-verify fixture catalog validates clean" do
      assert CatalogValidator.validate(TestFixtures.verify_fixture_catalog()) == []
    end

    test "a second {:verify, _} stage is rejected at load" do
      verify2 =
        stage(
          name: "verify2",
          unit: {:verify, "default"},
          lens: "verify2",
          routes: ["code"],
          sub: ["code-written"],
          pub: ["clean:verify2", "findings:verify2", "scope-shift"]
        )

      catalog = Map.put(TestFixtures.verify_fixture_catalog(), "verify2", verify2)
      found = inspect(["verify", "verify2"])

      assert CatalogValidator.validate(catalog) == [
               "catalog: at most one {:verify, _} stage is supported (found: #{found}) — " <>
                 "the composer retains a single verify certificate"
             ]
    end

    test "a lens-less verify stage is flagged" do
      cat = %{
        "verify" =>
          stage(
            name: "verify",
            unit: {:verify, "default"},
            routes: ["code"],
            sub: ["request-received"],
            pub: ["scope-shift"]
          )
      }

      problems = CatalogValidator.validate(cat)
      assert Enum.any?(problems, &String.contains?(&1, "verify stage must carry a `lens`"))
    end
  end

  # Item 10 remediation (review P2): the evidence floor rides synthetic
  # identity tokens with no catalog stage behind them — artifact producer
  # "evidence", the `finding_rounds["evidence"]` round, the "evidence:ac"
  # breach-ledger key. A real stage named after one (or claiming the
  # "evidence" lens) would silently conflate with the engine's records, and
  # nothing else bans colons in stage names — so the reservation is enforced
  # at load, never assumed.
  describe "reserved evidence identity (invariant 12)" do
    defp reserved_name_catalog(name) do
      %{
        name =>
          stage(
            name: name,
            unit: {:worker_template, "coder"},
            routes: ["code"],
            sub: ["request-received"],
            pub: ["scope-shift"],
            task: "t"
          )
      }
    end

    test "a stage named \"evidence\" is rejected at load" do
      assert ["evidence: stage name `evidence` is reserved" <> _rest] =
               CatalogValidator.validate(reserved_name_catalog("evidence"))
    end

    test "a stage named \"evidence:ac\" (the breach-ledger key) is rejected at load" do
      assert ["evidence:ac: stage name `evidence:ac` is reserved" <> _rest] =
               CatalogValidator.validate(reserved_name_catalog("evidence:ac"))
    end

    test "a stage carrying lens \"evidence\" is rejected at load" do
      cat = %{
        "review-e" =>
          stage(
            name: "review-e",
            unit: {:worker_template, "reviewer"},
            routes: ["code"],
            sub: ["request-received"],
            pub: ["clean:evidence", "findings:evidence", "scope-shift"],
            lens: "evidence",
            task: "t"
          )
      }

      assert ["review-e: `lens` \"evidence\" is reserved" <> _rest] =
               CatalogValidator.validate(cat)
    end

    test "a non-reserved lens on the same shape passes" do
      cat = %{
        "review-s" =>
          stage(
            name: "review-s",
            unit: {:worker_template, "reviewer"},
            routes: ["code"],
            sub: ["request-received"],
            pub: ["clean:security", "findings:security", "scope-shift"],
            lens: "security",
            task: "t"
          )
      }

      assert CatalogValidator.validate(cat) == []
    end
  end

  # AR-4: pins WHY the fixer's findings feed must be out-of-band. If the fixer
  # declared `findings` as a real data input, `graph.ex` would add reviewer→fixer
  # edges; with the existing `fixer→reviewer` edge (the reviewers optional-input
  # `fix`) that is a 2-cycle invariant 10 rejects at load. The shipped catalog
  # avoids it by feeding findings through producerless optional inputs
  # (`review-feedback` / `review-action`) the loop injects.
  test "a producer-backed `findings` input on the fixer would cycle (why the feed is out-of-band)" do
    catalog = Catalog.all()
    fixer = catalog["fixer"]
    bad_fixer = %{fixer | input: %{fixer.input | required: ["diff", "findings"]}}
    bad = %{catalog | "fixer" => bad_fixer}

    # The shipped catalog is clean; only the producer-backed variant cycles.
    assert CatalogValidator.validate(catalog) == []
    assert Enum.any?(CatalogValidator.validate(bad), &String.contains?(&1, "cycle"))
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
