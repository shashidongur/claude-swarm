# sanitize.jq — render-time neutralisation of role-provided text (spec §11.2).
#
# `<!--` → `<!-​-`, `-->` → `-​->`, `@x` → `@​x` (U+200B zero-width space in each), so a
# string that came from a role can never plant a marker or a mention in a comment the
# dispatcher authors. U+200B is what lib/sh/common.sh's self-check expects; a different
# zero-width code point would make `sanitize` there fall back to sed.
#
# Two ways to use it:
#   jq -Rrs -f lib/jq/sanitize.jq < text          the file's main expression
#   def sanitize: …  (copied into render-*.jq)   jq refuses to `include` a module that
#                                                also carries a main expression, so the
#                                                renderers inline the same definition.
#
# `sanitize` works on a string and passes every other value through; `sanitize_all`
# walks a document and sanitises every string in it.
def sanitize:
  if type != "string" then .
  else gsub("<!--"; "<!-​-")
     | gsub("-->"; "-​->")
     | gsub("@(?<c>[A-Za-z0-9-])"; "@​\(.c)")
  end;

def sanitize_all: walk(if type == "string" then sanitize else . end);

sanitize_all
