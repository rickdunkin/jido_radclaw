defmodule JidoClaw.Solutions.FingerprintTest do
  use ExUnit.Case, async: true

  alias JidoClaw.Solutions.Fingerprint

  # ---------------------------------------------------------------------------
  # generate/2
  # ---------------------------------------------------------------------------

  describe "generate/2" do
    test "should return a Fingerprint struct" do
      fp = Fingerprint.generate("build an HTTP route handler")

      assert %Fingerprint{} = fp
    end

    test "should compute SHA-256 signature" do
      fp = Fingerprint.generate("build an HTTP route handler", language: "elixir")

      # SHA-256 → 64 lowercase hex chars
      assert is_binary(fp.signature)
      assert byte_size(fp.signature) == 64
      assert fp.signature =~ ~r/^[0-9a-f]+$/
    end

    test "should extract domain from description" do
      fp = Fingerprint.generate("handle HTTP requests and responses")

      assert fp.domain == "web"
    end

    test "should extract target from description" do
      fp = Fingerprint.generate("implement login and JWT token generation")

      assert fp.target == "authentication"
    end

    test "should extract search terms from description" do
      fp = Fingerprint.generate("implement login and JWT token generation")

      assert is_list(fp.search_terms)
      assert length(fp.search_terms) > 0
      # Stopwords like "and" must be absent
      refute "and" in fp.search_terms
    end

    test "should pass through ecosystem from opts" do
      ecosystem = ["elixir", "phoenix", "ecto"]
      fp = Fingerprint.generate("run database queries", ecosystem: ecosystem)

      assert fp.ecosystem == ecosystem
    end

    test "should pass through versions from opts" do
      versions = %{"elixir" => "1.17", "phoenix" => "1.7"}
      fp = Fingerprint.generate("build a controller", versions: versions)

      assert fp.versions == versions
    end

    test "should store raw_description unchanged" do
      desc = "  Build a REST API endpoint  "
      fp = Fingerprint.generate(desc)

      assert fp.raw_description == desc
    end

    test "should store nil error_class when not provided" do
      fp = Fingerprint.generate("do something")

      assert is_nil(fp.error_class)
    end

    test "should store provided error_class" do
      fp = Fingerprint.generate("crash at runtime", error_class: "runtime")

      assert fp.error_class == "runtime"
    end
  end

  # ---------------------------------------------------------------------------
  # signature/3
  # ---------------------------------------------------------------------------

  describe "signature/3" do
    test "should produce deterministic hash" do
      sig1 = Fingerprint.signature("build an auth system", "elixir", "phoenix")
      sig2 = Fingerprint.signature("build an auth system", "elixir", "phoenix")

      assert sig1 == sig2
    end

    test "should normalize whitespace and case" do
      sig1 = Fingerprint.signature("Build  An Auth  System", "Elixir", "Phoenix")
      sig2 = Fingerprint.signature("build an auth system", "Elixir", "Phoenix")

      assert sig1 == sig2
    end

    test "should collapse interior whitespace before hashing" do
      sig1 = Fingerprint.signature("build  an   auth system", "elixir")
      sig2 = Fingerprint.signature("build an auth system", "elixir")

      assert sig1 == sig2
    end

    test "should handle nil framework" do
      sig_nil = Fingerprint.signature("some problem", "elixir", nil)
      sig_omit = Fingerprint.signature("some problem", "elixir")

      assert sig_nil == sig_omit
    end

    test "should differ when framework differs" do
      sig1 = Fingerprint.signature("some problem", "elixir", "phoenix")
      sig2 = Fingerprint.signature("some problem", "elixir", "plug")

      refute sig1 == sig2
    end

    test "should differ when language differs" do
      sig1 = Fingerprint.signature("sort a list", "elixir")
      sig2 = Fingerprint.signature("sort a list", "python")

      refute sig1 == sig2
    end

    test "should produce a 64-character lowercase hex string" do
      sig = Fingerprint.signature("any description", "elixir")

      assert byte_size(sig) == 64
      assert sig =~ ~r/^[0-9a-f]+$/
    end
  end

  # ---------------------------------------------------------------------------
  # extract_domain/1
  # ---------------------------------------------------------------------------

  describe "extract_domain/1" do
    test "should detect \"web\" domain" do
      assert Fingerprint.extract_domain("handle an HTTP request") == "web"
      assert Fingerprint.extract_domain("set up a route for the homepage") == "web"
      assert Fingerprint.extract_domain("manage user sessions and cookies") == "web"
    end

    test "should detect \"database\" domain" do
      assert Fingerprint.extract_domain("write a SQL query to fetch users") == "database"
      assert Fingerprint.extract_domain("create a migration for the posts table") == "database"
    end

    test "should detect \"api\" domain" do
      assert Fingerprint.extract_domain("design a REST api") == "api"
      # "endpoint" also appears in the web domain keywords (checked first),
      # so use a description without web-domain terms
      assert Fingerprint.extract_domain("build a graphql interface") == "api"
    end

    test "should detect \"cli\" domain" do
      assert Fingerprint.extract_domain("parse command-line arguments and flags") == "cli"
      assert Fingerprint.extract_domain("read from stdin and write to stdout") == "cli"
    end

    test "should detect \"devops\" domain" do
      assert Fingerprint.extract_domain("deploy the app with Docker") == "devops"
      assert Fingerprint.extract_domain("set up a CI pipeline") == "devops"
    end

    test "should detect \"testing\" domain" do
      assert Fingerprint.extract_domain("write a test with mock and assert") == "testing"
      assert Fingerprint.extract_domain("create a fixture for the test suite") == "testing"
    end

    test "should return nil for unrecognized descriptions" do
      assert Fingerprint.extract_domain("foo bar baz") == nil
      assert Fingerprint.extract_domain("") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # extract_target/1
  # ---------------------------------------------------------------------------

  describe "extract_target/1" do
    test "should detect \"authentication\" target" do
      assert Fingerprint.extract_target("implement JWT token login") == "authentication"

      assert Fingerprint.extract_target("handle logout and credential refresh") ==
               "authentication"
    end

    test "should detect \"routing\" target" do
      assert Fingerprint.extract_target("add a redirect in the router") == "routing"
      assert Fingerprint.extract_target("configure plug middleware for routing") == "routing"
    end

    test "should detect \"deployment\" target" do
      assert Fingerprint.extract_target("build a Docker image for deployment") == "deployment"
      assert Fingerprint.extract_target("release a new build artifact") == "deployment"
    end

    test "should detect \"migrations\" target" do
      assert Fingerprint.extract_target("write a migration to alter the column") == "migrations"
      assert Fingerprint.extract_target("migrate the schema") == "migrations"
    end

    test "should detect \"caching\" target" do
      assert Fingerprint.extract_target("store results in redis cache with ttl") == "caching"
      assert Fingerprint.extract_target("use ETS for caching") == "caching"
    end

    test "should detect \"performance\" target" do
      assert Fingerprint.extract_target("reduce latency and improve throughput") == "performance"
    end

    test "should detect \"networking\" target" do
      assert Fingerprint.extract_target("open a websocket channel connection") == "networking"
    end

    test "should return nil for generic descriptions" do
      assert Fingerprint.extract_target("write some code") == nil
      assert Fingerprint.extract_target("") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # extract_search_terms/1
  # ---------------------------------------------------------------------------

  describe "extract_search_terms/1" do
    test "should tokenize and lowercase" do
      terms = Fingerprint.extract_search_terms("Build A GenServer")

      assert "build" in terms
      assert "genserver" in terms
    end

    test "should remove stopwords" do
      terms = Fingerprint.extract_search_terms("the quick brown fox")

      refute "the" in terms
      refute "a" in terms
    end

    test "should remove tokens shorter than 3 chars" do
      # "an" is 2 chars and a stopword; "is" is 2 chars and a stopword;
      # test a non-stopword short token too
      terms = Fingerprint.extract_search_terms("ox go elk")

      # "ox" = 2 chars, "go" = 2 chars → filtered
      refute "ox" in terms
      refute "go" in terms
      # "elk" = 3 chars → kept
      assert "elk" in terms
    end

    test "should deduplicate" do
      terms = Fingerprint.extract_search_terms("phoenix phoenix phoenix")

      assert Enum.count(terms, &(&1 == "phoenix")) == 1
    end

    test "should sort the result" do
      terms = Fingerprint.extract_search_terms("supervisor router genserver")

      assert terms == Enum.sort(terms)
    end

    test "should handle punctuation as token delimiters" do
      terms = Fingerprint.extract_search_terms("auth,token;jwt.session")

      assert "auth" in terms
      assert "token" in terms
      assert "jwt" in terms
      assert "session" in terms
    end

    test "should return empty list for blank input" do
      assert Fingerprint.extract_search_terms("") == []
      assert Fingerprint.extract_search_terms("   ") == []
    end
  end

  # ---------------------------------------------------------------------------
  # match_score/2
  # ---------------------------------------------------------------------------

  describe "match_score/2" do
    test "should return 1.0 for identical signatures" do
      fp = Fingerprint.generate("build a GenServer with state", language: "elixir")

      assert Fingerprint.match_score(fp, fp) == 1.0
    end

    test "should return > 0 for fingerprints with same domain and overlapping search terms" do
      fp1 =
        Fingerprint.generate("handle an HTTP request in a web app",
          language: "elixir",
          ecosystem: ["elixir"]
        )

      fp2 =
        Fingerprint.generate("manage HTTP responses for a web endpoint",
          language: "elixir",
          ecosystem: ["elixir"]
        )

      score = Fingerprint.match_score(fp1, fp2)
      assert score > 0.0
    end

    test "should return 0.0 for completely different fingerprints" do
      fp1 =
        Fingerprint.generate("abc xyz qqq",
          ecosystem: [],
          language: "elixir"
        )

      fp2 =
        Fingerprint.generate("mno pqr stu",
          ecosystem: [],
          language: "python"
        )

      score = Fingerprint.match_score(fp1, fp2)
      # Domains and targets will both be nil, ecosystems empty → 0.0
      # (nil == nil is guarded by `not is_nil` in match_score)
      assert score == 0.0
    end

    test "should weight ecosystem jaccard at 0.25" do
      # Build two fingerprints with identical ecosystem but nothing else overlapping.
      # Use descriptions that produce no domain/target/search-term overlap.
      fp1 = %Fingerprint{
        signature: "aaa",
        domain: nil,
        target: nil,
        error_class: nil,
        ecosystem: ["elixir", "phoenix"],
        versions: %{},
        search_terms: [],
        raw_description: ""
      }

      fp2 = %Fingerprint{
        signature: "bbb",
        domain: nil,
        target: nil,
        error_class: nil,
        ecosystem: ["elixir", "phoenix"],
        versions: %{},
        search_terms: [],
        raw_description: ""
      }

      score = Fingerprint.match_score(fp1, fp2)
      # full ecosystem jaccard (identical) → 0.25 * 1.0 = 0.25
      assert_in_delta score, 0.25, 0.0001
    end

    test "should weight search_terms jaccard at 0.30" do
      terms = ["genserver", "supervisor", "state"]

      fp1 = %Fingerprint{
        signature: "aaa",
        domain: nil,
        target: nil,
        error_class: nil,
        ecosystem: [],
        versions: %{},
        search_terms: terms,
        raw_description: ""
      }

      fp2 = %Fingerprint{
        signature: "bbb",
        domain: nil,
        target: nil,
        error_class: nil,
        ecosystem: [],
        versions: %{},
        search_terms: terms,
        raw_description: ""
      }

      score = Fingerprint.match_score(fp1, fp2)
      # full search_terms jaccard (identical) → 0.30 * 1.0 = 0.30
      assert_in_delta score, 0.30, 0.0001
    end

    test "should not count nil domain/target as matching" do
      fp1 = %Fingerprint{
        signature: "aaa",
        domain: nil,
        target: nil,
        error_class: nil,
        ecosystem: [],
        versions: %{},
        search_terms: [],
        raw_description: ""
      }

      fp2 = %Fingerprint{
        signature: "bbb",
        domain: nil,
        target: nil,
        error_class: nil,
        ecosystem: [],
        versions: %{},
        search_terms: [],
        raw_description: ""
      }

      assert Fingerprint.match_score(fp1, fp2) == 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # jaccard/2
  # ---------------------------------------------------------------------------

  describe "jaccard/2" do
    test "should return 1.0 for identical lists" do
      assert Fingerprint.jaccard(["a", "b", "c"], ["a", "b", "c"]) == 1.0
    end

    test "should return 0.0 for disjoint lists" do
      assert Fingerprint.jaccard(["a", "b"], ["c", "d"]) == 0.0
    end

    test "should return 0.0 for two empty lists" do
      assert Fingerprint.jaccard([], []) == 0.0
    end

    test "should compute correct similarity for overlapping lists" do
      # list1: {"a","b"}, list2: {"b","c","d"}
      # intersection: {"b"} → size 1
      # union: {"a","b","c","d"} → size 4
      # jaccard = 1/4 = 0.25
      result = Fingerprint.jaccard(["a", "b"], ["b", "c", "d"])

      assert_in_delta result, 1 / 4, 0.0001
    end

    test "should handle one empty list" do
      assert Fingerprint.jaccard(["a", "b"], []) == 0.0
      assert Fingerprint.jaccard([], ["a", "b"]) == 0.0
    end

    test "should treat lists as sets (ignore duplicates)" do
      # ["a","a","b"] as a set is {"a","b"}; ["a","b","b"] as a set is {"a","b"}
      assert Fingerprint.jaccard(["a", "a", "b"], ["a", "b", "b"]) == 1.0
    end
  end
end
