{
  // Provide an out field that is all the top-level field with their .out
  // members, if available.
  useOut(o): if std.type(o) == 'object' && std.objectHas(o, 'out')
  then o.out else o,
  FieldsOut: {
    local top = self,
    out: {
      [f]:
        // If a field value has an 'out' member, use that.  Otherwise,
        // use the value itself.
        $.useOut(top[f])
      for f in std.objectFields(top)
      if f != 'out'
    },
  },

  // A template string, represented so that mutation is reasonable.
  TemplateStringBase: {
    content: error 'TemplateStringBase requires content',
    out: '${%s}' % self.content,
  },

  merged_array(val): std.foldl(function(l, r) l + r, val, {}),

  // Provide an out field where the top-level objects are all merged, and
  // their field names are thrown away.
  MergedOut: {
    out: $.merged_array(std.objectValues($.fields_out(self))),
  },
  ItemBase: {
    local top = self,
    _cls:: 'ItemBase',

    // Kind is a top-level kind like 'resource', 'provider', 'data'
    kind: error '%s requires kind' % self._cls,

    // Type is a data / resource / provider type like aws_s3_bucket
    type: error '%s requires type' % self._cls,

    // Name is the tofu-specific name, null for providers
    name:
      if std.objectHas(self, 'kind') && self.kind == 'provider' then null
      else error '%s requires name (but it may be null)' % self._cls,

    // The arguments of this item.
    arguments: error '%s requires arguments' % self._cls,
    local arguments = ($.FieldsOut + self.arguments).out,

    subpath: $.TemplateStringBase {
      elements: [top.type] + if top.name == null then [] else [top.name],
      content: std.join('.', self.elements),
    },

    // The path through tofu identifiers, for this item, ending in the name if
    // applicable.  (A templateString)
    path: top.subpath { elements: [top.kind] + super.elements },

    // The id of this item, as a TemplateString.
    id: self.attr('id'),

    // A named attribute of this item, as a TemplateString.
    attr(name): self.path { elements+: [name] },

    // The actual OpenTofu JSON
    out: {
      [top.kind]+: {
        [top.type]+: if top.name == null then arguments else {
          [top.name]+: arguments,
        },
      },
    },
  },

  // A specialized ItemBase for a resource
  ResourceBase: self.ItemBase {
    local top = self,
    _cls:: 'ResourceBase',
    kind: 'resource',
    out+: {
      [if std.get(top, 'import_id') != null then 'import']+:
        [$.FieldsOut {
          id: top.import_id,
          to: top.subpath.content,
        }.out],
    },
  },

  // FieldsOut comes last so that here, self.out is overridden
  fields_out(val): (val + $.FieldsOut).out,

  // An item for outputs.
  OutputBase: {
    local children = $.fields_out(self),
    out: {
      output: { [x]: {
        value: children[x],
      } for x in std.objectFields(children) },
    },
  },
}
