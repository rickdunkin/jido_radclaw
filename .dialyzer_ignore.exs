# Findings we can't fix locally. Each entry is scoped to a single file +
# warning kind so any other warning in the same file still surfaces. The
# 3-tuple {path, kind, line} form is unreliable on OTP 28: dialyzer's
# location field is a {line, column} tuple, not a bare line integer, so
# the equality check in dialyxir's filter never matches. The 2-tuple
# {path, kind} form is documented and stable.
[
  # postgrex 0.22.1 — improper_list_constr at type_module.ex:1045. Upstream
  # behavior; revisit on the next postgrex bump.
  {"deps/postgrex/lib/postgrex/type_module.ex", :improper_list_constr}
]
