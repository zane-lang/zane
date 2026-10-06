module Zane
  # The command's own version. It is not tied to a compiler version: one
  # installed `zane` builds projects pinned to any compiler (docs/design/cli.md §1).
  # Release builds supply their tag; local builds keep the development version.
  {% if env("ZANE_CLI_VERSION") && env("ZANE_CLI_VERSION") != "" %}
    VERSION = {{ env("ZANE_CLI_VERSION") }}
  {% else %}
    VERSION = "v0.0-dev"
  {% end %}
end
