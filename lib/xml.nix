# A small structural XML builder.
#
# Documents are built as values -- `elem "foo" { bar = "baz"; } [ ... ]` rather
# than by pasting strings together -- and rendered once at the end. The point is
# that escaping and quoting happen in exactly one place, and that a malformed
# document is a type error at eval time rather than a mystery when whatever
# consumes the XML rejects it.
#
# Rendering deliberately matches the hand-written output it replaces: attributes
# single-quoted (which is what SMF manifests use), two-space indent per level,
# empty elements self-closed.
{ lib }:

let
  inherit (lib)
    concatMapStrings
    concatStrings
    escapeXML
    isBool
    boolToString
    mapAttrsToList
    optionalString
    head
    length
    ;

  # `toString true` is "1", which is not a valid XML boolean anywhere we care
  # about -- SMF wants "true"/"false" -- so booleans are spelled out.
  fmtValue = v: if isBool v then boolToString v else toString v;

  # An attribute whose value is `null` is omitted entirely, which is what makes
  # optional attributes expressible without the caller assembling strings.
  renderAttrs =
    attrs:
    concatStrings (
      mapAttrsToList (
        name: value: optionalString (value != null) " ${name}='${escapeXML (fmtValue value)}'"
      ) attrs
    );
in
rec {
  # elem : String -> AttrSet -> [Node] -> Node
  elem = name: attrs: children: {
    _type = "element";
    inherit name attrs children;
  };

  # A self-closing element: `leaf "service_fmri" { value = "svc:/foo"; }`.
  leaf = name: attrs: elem name attrs [ ];

  # Character data. Escaped on render like everything else.
  text = value: {
    _type = "text";
    inherit value;
  };

  # Raw, unescaped output -- for the XML declaration and DOCTYPE, which are not
  # elements. Do not use it for anything derived from configuration.
  raw = value: {
    _type = "raw";
    inherit value;
  };

  # render : String -> Node -> String
  #
  # `indent` is the prefix for this node; children get two more spaces. Every
  # node renders with a trailing newline, so concatenating siblings is enough.
  render =
    indent: node:
    if node._type == "raw" then
      "${indent}${node.value}\n"
    else if node._type == "text" then
      "${indent}${escapeXML (fmtValue node.value)}\n"
    else if node.children == [ ] then
      "${indent}<${node.name}${renderAttrs node.attrs}/>\n"
    # An element whose only child is text renders on one line. This is not
    # cosmetic: the content of such an element *is* the string, so indenting it
    # onto its own line would silently prepend a newline and spaces to the
    # value. SMF's <loctext> is exactly this case -- the common name a service
    # reports would otherwise arrive with whitespace around it.
    else if length node.children == 1 && (head node.children)._type == "text" then
      "${indent}<${node.name}${renderAttrs node.attrs}>"
      + escapeXML (fmtValue (head node.children).value)
      + "</${node.name}>\n"
    else
      "${indent}<${node.name}${renderAttrs node.attrs}>\n"
      + renderMany "${indent}  " node.children
      + "${indent}</${node.name}>\n";

  renderMany = indent: nodes: concatMapStrings (render indent) nodes;

  # `<!-- ... -->`. The text is not escaped -- XML has no escape mechanism
  # inside comments -- so it must not contain `--`.
  comment = value: raw "<!-- ${value} -->";

  # A whole document: the declaration, an optional DOCTYPE and comment, then
  # the root element.
  document =
    {
      doctype ? null,
      comment ? null,
    }:
    root:
    render "" (raw "<?xml version='1.0'?>")
    + optionalString (doctype != null) (render "" (raw doctype))
    + optionalString (comment != null) (render "" (raw "<!-- ${comment} -->"))
    + render "" root;
}
