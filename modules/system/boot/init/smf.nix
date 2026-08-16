{
  pkgs,
  config,
  lib,
  ...
}:

# Native SMF layer, in the same spirit as ./freebsd-rc.nix and ./openbsd-rc.nix:
# it models the *host* init system's own concepts (here: service manifests as
# consumed by svccfg(8) and svc.startd(8)) and renders them to files. The
# portable `init.services` abstraction is translated into this by
# ./portable/illumos.nix, and NixOS modular services are translated into it by
# ../../service/illumos/system.nix.
#
# The rendered XML is a `service_bundle type='manifest'` document conforming to
# service_bundle.dtd.1 (usr/src/cmd/svc/dtd/service_bundle.dtd.1 in illumos-gate).
# Element order below is *significant*: the DTD content models are sequences,
# not choices.

with lib;
let
  cfg = config.smf;

  # XML is built structurally -- see ../../../../lib/xml.nix -- rather than by
  # pasting strings together. Escaping and quoting then happen in exactly one
  # place, optional attributes are expressed by passing `null`, and an element
  # with no children self-closes without anyone having to remember to write it
  # two different ways.
  xml = import ../../../../lib/xml.nix { inherit lib; };
  inherit (xml) elem leaf text;

  # <propval>/<property> ------------------------------------------------------

  propvalNode =
    name: p:
    if p.values == null then
      leaf "propval" {
        inherit name;
        inherit (p) type;
        inherit (p) value;
      }
    else
      elem "property"
        {
          inherit name;
          inherit (p) type;
        }
        [
          (elem "${p.type}_list" { } (map (v: leaf "value_node" { value = v; }) p.values))
        ];

  propertyGroupNode =
    name: pg:
    elem "property_group"
      {
        inherit name;
        inherit (pg) type;
      }
      (mapAttrsToList propvalNode pg.properties);

  # <dependency>/<dependent> -------------------------------------------------

  # A `<dependency>` holding more than one `<service_fmri>` kills svc.configd
  # during `svccfg import`. The import dies with
  #
  #     svccfg: Could not delete svc:/TEMP/<service> (repository connection broken).
  #
  # which is ECONNABORTED from the door call -- configd is gone, and gone
  # silently, without the message its own error paths would have printed. The
  # repository is left incomplete and svc.startd then puts everything into
  # maintenance. Bisected by narrowing the one manifest that had two FMRIs in a
  # single block (sshd) down to one, after which all nine manifests import
  # cleanly.
  #
  # So emit one block per FMRI. For the "all" groupings that is the same thing:
  # requiring A and B in one block is requiring A in one block and B in another.
  #
  # It is *not* the same for `require_any` ("any one of these") or `exclude_all`,
  # so those are left alone and will still hit the bug -- better than silently
  # turning "any" into "all". Nothing generates them today.
  #
  # TODO drop this once configd is fixed. The real bug is configd's, and any
  # hand-written illumos manifest hits it too, where multi-FMRI dependencies are
  # entirely normal.
  splittableGrouping = g: g == "require_all" || g == "optional_all";

  fmriNodes = fmris: map (f: leaf "service_fmri" { value = f; }) fmris;

  # Returns a *list* of nodes, since one dependency may split into several.
  dependencyNodes =
    name: d:
    let
      block =
        suffix: fmris:
        elem "dependency" {
          name = name + suffix;
          inherit (d) grouping;
          restart_on = d.restartOn;
          inherit (d) type;
        } (fmriNodes fmris);
    in
    if splittableGrouping d.grouping && length d.fmris > 1 then
      imap0 (i: f: block "-${toString i}" [ f ]) d.fmris
    else
      [ (block "" d.fmris) ];

  dependentNode =
    name: d:
    elem "dependent" {
      inherit name;
      inherit (d) grouping;
      restart_on = d.restartOn;
    } (fmriNodes d.fmris);

  # <method_context> ---------------------------------------------------------

  hasMethodContext =
    mc:
    mc.user != null
    || mc.workingDirectory != null
    || mc.project != null
    || mc.resourcePool != null
    || mc.environment != { };

  # A list, so that an absent context contributes nothing to its parent.
  methodContextNodes =
    mc:
    optional (hasMethodContext mc) (
      elem "method_context"
        {
          working_directory = mc.workingDirectory;
          inherit (mc) project;
          resource_pool = mc.resourcePool;
        }
        (
          optional (mc.user != null) (leaf "method_credential" {
            inherit (mc) user group;
            supp_groups =
              if mc.supplementaryGroups == [ ] then null else concatStringsSep "," mc.supplementaryGroups;
            inherit (mc) privileges;
            limit_privileges = mc.limitPrivileges;
          })
          ++ optional (mc.environment != { }) (
            elem "method_environment" { } (
              mapAttrsToList (n: v: leaf "envvar" {
                name = n;
                value = v;
              }) mc.environment
            )
          )
        )
    );

  # <exec_method> ------------------------------------------------------------

  execMethodNode =
    name: m:
    elem "exec_method" {
      inherit (m) type;
      inherit name;
      inherit (m) exec;
      timeout_seconds = m.timeoutSeconds;
    } (methodContextNodes m.methodContext);

  # <template> ---------------------------------------------------------------

  loctextNode = s: elem "loctext" { "xml:lang" = "C"; } [ (text s) ];

  templateNode =
    t:
    elem "template" { } (
      [ (elem "common_name" { } [ (loctextNode t.commonName) ]) ]
      ++ optional (t.description != null) (elem "description" { } [ (loctextNode t.description) ])
      ++ optional (t.manpages != [ ] || t.docLinks != [ ]) (
        elem "documentation" { } (
          map (m: leaf "manpage" { inherit (m) title section manpath; }) t.manpages
          ++ map (l: leaf "doc_link" { inherit (l) name uri; }) t.docLinks
        )
      )
    );

  # <instance> ---------------------------------------------------------------

  # The child order below is not decoration: the DTD's content models are
  # sequences, not choices, so a manifest whose elements are correct but
  # misordered is rejected outright.
  commonChildren = x:
    concatLists (mapAttrsToList dependencyNodes x.dependencies)
    ++ mapAttrsToList dependentNode x.dependents
    ++ methodContextNodes x.methodContext
    ++ mapAttrsToList execMethodNode x.execMethods
    ++ mapAttrsToList propertyGroupNode x.propertyGroups;

  instanceNode =
    name: inst:
    elem "instance" {
      inherit name;
      inherit (inst) enabled;
    } (commonChildren inst);

  # <service> / <service_bundle> ---------------------------------------------

  serviceNode =
    svc:
    elem "service_bundle"
      {
        type = "manifest";
        name = svc.bundleName;
      }
      [
        (elem "service"
          {
            inherit (svc) name type;
            version = svc.version;
          }
          (
            optional svc.defaultInstance.enable (leaf "create_default_instance" {
              inherit (svc.defaultInstance) enabled;
            })
            ++ optional svc.singleInstance (leaf "single_instance" { })
            ++ commonChildren svc
            ++ mapAttrsToList instanceNode svc.instances
            ++ [
              (leaf "stability" { value = svc.stability; })
              (templateNode svc.template)
            ]
          )
        )
      ];

  renderService =
    svc:
    xml.document {
      doctype = "<!DOCTYPE service_bundle SYSTEM '/usr/share/lib/xml/dtd/service_bundle.dtd.1'>";
      comment = "Generated by nixbsd; do not edit.";
    } (serviceNode svc);

  # A file name for a manifest: svc:/site/nginx -> site/nginx.xml
  manifestPath = svc: "${svc.name}.xml";

  # buildPackages: a manifest is pure text. Building it with the cross stdenv
  # would make `smf.manifests` depend on a cross-compiled bash and coreutils,
  # neither of which builds for illumos yet.
  manifestDir = pkgs.buildPackages.runCommand "smf-manifests" { } (
    ''
      mkdir -p $out
    ''
    + concatStrings (
      mapAttrsToList (_: svc: ''
        mkdir -p "$out/$(dirname ${escapeShellArg (manifestPath svc)})"
        ln -s ${svc.manifest} "$out/${manifestPath svc}"
      '') cfg.services
    )
  );

  # Option types -------------------------------------------------------------

  propertyType = types.submodule (
    { config, ... }:
    {
      options = {
        type = mkOption {
          type = types.enum [
            "count"
            "integer"
            "opaque"
            "host"
            "hostname"
            "net_address"
            "net_address_v4"
            "net_address_v6"
            "time"
            "astring"
            "ustring"
            "boolean"
            "fmri"
            "uri"
          ];
          default = "astring";
          description = "SMF property type.";
        };
        value = mkOption {
          type =
            with types;
            nullOr (oneOf [
              str
              int
              bool
            ]);
          default = null;
          description = "Single value, rendered as `<propval>`. Mutually exclusive with `values`.";
        };
        values = mkOption {
          type =
            with types;
            nullOr (
              listOf (oneOf [
                str
                int
                bool
              ])
            );
          default = null;
          description = "List of values, rendered as `<property>` with a `*_list`. Mutually exclusive with `value`.";
        };
      };
    }
  );

  propertyGroupType = types.submodule {
    options = {
      type = mkOption {
        type = types.str;
        default = "application";
        example = "framework";
        description = "Property group category: `framework`, `application`, `template`, ...";
      };
      properties = mkOption {
        type = types.attrsOf propertyType;
        default = { };
        description = "Properties in this group.";
      };
    };
  };

  dependencyType = types.submodule {
    options = {
      grouping = mkOption {
        type = types.enum [
          "require_all"
          "require_any"
          "exclude_all"
          "optional_all"
        ];
        default = "require_all";
        description = "How the listed FMRIs combine to satisfy this dependency.";
      };
      restartOn = mkOption {
        type = types.enum [
          "error"
          "restart"
          "refresh"
          "none"
        ];
        default = "none";
        description = "Which events on the depended-upon services restart this one.";
      };
      type = mkOption {
        type = types.str;
        default = "service";
        example = "path";
        description = "Dependency type: `service`, `path`, ...";
      };
      fmris = mkOption {
        type = types.listOf types.str;
        example = [ "svc:/system/filesystem/local" ];
        description = "FMRIs depended upon.";
      };
    };
  };

  dependentType = types.submodule {
    options = {
      grouping = mkOption {
        type = types.enum [
          "require_all"
          "require_any"
          "exclude_all"
          "optional_all"
        ];
        default = "optional_all";
        description = "Grouping of the dependency installed into the named service.";
      };
      restartOn = mkOption {
        type = types.enum [
          "error"
          "restart"
          "refresh"
          "none"
        ];
        default = "none";
        description = "Which events on this service restart the dependent.";
      };
      fmris = mkOption {
        type = types.listOf types.str;
        example = [ "svc:/milestone/multi-user-server" ];
        description = "FMRIs that should be made to depend on this service.";
      };
    };
  };

  methodContextType = types.submodule {
    options = {
      user = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "User to run methods as (`<method_credential user=…>`).";
      };
      group = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Primary group for methods.";
      };
      supplementaryGroups = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Supplementary groups (`supp_groups`).";
      };
      privileges = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "basic,net_privaddr";
        description = "Privilege set granted to methods, see {manpage}`privileges(7)`.";
      };
      limitPrivileges = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Limit privilege set for methods.";
      };
      workingDirectory = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Directory to run methods from. `:default` means the credential user's home.";
      };
      project = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Project to run methods in, see {manpage}`project(5)`.";
      };
      resourcePool = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Resource pool to run methods on.";
      };
      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Environment variables for methods (`<method_environment>`). Note that
          svc.startd otherwise supplies only a minimal environment.
        '';
      };
    };
  };

  execMethodType = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [
          "method"
          "monitor"
        ];
        default = "method";
        description = "`method` or `monitor`.";
      };
      exec = mkOption {
        type = types.str;
        example = "/lib/svc/method/sshd start";
        description = ''
          String passed to {manpage}`exec(2)` by the restarter. The tokens
          `:kill`, `:kill_process_group` and `:true` are also accepted by
          svc.startd.
        '';
      };
      timeoutSeconds = mkOption {
        type = types.int;
        default = 60;
        description = "How long the restarter waits for the method. `0` or `-1` means no timeout.";
      };
      methodContext = mkOption {
        type = methodContextType;
        default = { };
        description = "Per-method execution context, overriding the service-level one.";
      };
    };
  };

  templateType = types.submodule {
    options = {
      commonName = mkOption {
        type = types.str;
        description = "Short human-readable name, under 60 characters. Required by the DTD.";
      };
      description = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Longer description of the service.";
      };
      manpages = mkOption {
        default = [ ];
        description = "Manual pages documenting this service.";
        type = types.listOf (
          types.submodule {
            options = {
              title = mkOption { type = types.str; };
              section = mkOption {
                type = types.str;
                default = "8";
              };
              manpath = mkOption {
                type = types.str;
                default = "/share/man";
              };
            };
          }
        );
      };
      docLinks = mkOption {
        default = [ ];
        description = "External documentation links.";
        type = types.listOf (
          types.submodule {
            options = {
              name = mkOption { type = types.str; };
              uri = mkOption { type = types.str; };
            };
          }
        );
      };
    };
  };

  # Shared between <service> and <instance>.
  commonServiceOptions = {
    dependencies = mkOption {
      type = types.attrsOf dependencyType;
      default = { };
      description = "`<dependency>` elements, keyed by dependency name.";
    };
    dependents = mkOption {
      type = types.attrsOf dependentType;
      default = { };
      description = "`<dependent>` elements: dependencies installed into *other* services.";
    };
    methodContext = mkOption {
      type = methodContextType;
      default = { };
      description = "Default execution context for all methods.";
    };
    execMethods = mkOption {
      type = types.attrsOf execMethodType;
      default = { };
      description = ''
        `<exec_method>` elements. svc.startd understands `start`, `stop` and
        `refresh`.
      '';
    };
    propertyGroups = mkOption {
      type = types.attrsOf propertyGroupType;
      default = { };
      description = "`<property_group>` elements.";
    };
  };
in
{
  options.smf = {
    services = mkOption {
      default = { };
      description = ''
        SMF services, each rendered to one service manifest XML document.

        The attribute name is the service name as it appears in the FMRI
        without the `svc:/` scheme prefix, e.g. `site/nginx` for
        `svc:/site/nginx:default`. Local (non-illumos-delivered) services
        belong under `site/` by convention.
      '';
      type = types.attrsOf (
        types.submodule (
          { name, config, ... }:
          {
            options = commonServiceOptions // {
              name = mkOption {
                type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_.,/-]*";
                description = "Service name, without the `svc:/` prefix.";
              };

              bundleName = mkOption {
                type = types.str;
                description = "Value of the `name` attribute on `<service_bundle>`.";
              };

              fmri = mkOption {
                type = types.str;
                readOnly = true;
                description = "Full FMRI of the default instance of this service.";
              };

              version = mkOption {
                type = types.int;
                default = 1;
                description = "Manifest version of this service.";
              };

              type = mkOption {
                type = types.enum [
                  "service"
                  "restarter"
                  "milestone"
                ];
                default = "service";
                description = ''
                  `service` for a normal service, `milestone` for a synthetic
                  service that only collects dependencies, `restarter` for a
                  delegated restarter.
                '';
              };

              singleInstance = mkOption {
                type = types.bool;
                default = true;
                description = "Emit `<single_instance/>`: at most one instance may exist.";
              };

              defaultInstance = {
                enable = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Emit `<create_default_instance/>`, creating the `:default` instance.";
                };
                enabled = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Whether the default instance starts at boot.";
                };
              };

              instances = mkOption {
                default = { };
                description = "Explicitly declared `<instance>` elements.";
                type = types.attrsOf (
                  types.submodule {
                    options = commonServiceOptions // {
                      enabled = mkOption {
                        type = types.bool;
                        default = true;
                        description = "Whether this instance starts at boot.";
                      };
                    };
                  }
                );
              };

              stability = mkOption {
                type = types.enum [
                  "Standard"
                  "Stable"
                  "Evolving"
                  "Unstable"
                  "External"
                  "Obsolete"
                ];
                default = "Unstable";
                description = "Interface stability of this service's properties, see {manpage}`attributes(7)`.";
              };

              template = mkOption {
                type = templateType;
                description = "`<template>` metadata. `commonName` is mandatory per the DTD.";
              };

              # Convenience wrappers over the `startd` framework property group.
              duration = mkOption {
                type = types.enum [
                  "contract"
                  "child"
                  "transient"
                ];
                default = "contract";
                description = ''
                  How svc.startd tracks the service, written to the `startd`
                  property group:

                  * `contract`: the start method forks and the daemon runs in a
                    process contract. The rough equivalent of systemd's
                    `Type=forking`.
                  * `child`: the start method *is* the daemon and stays in the
                    foreground; svc.startd waits on it. The rough equivalent of
                    `Type=simple`, sometimes called "wait" services.
                  * `transient`: the method runs to completion and the service
                    is then online with no lasting process, like `Type=oneshot`.
                '';
              };

              ignoreError = mkOption {
                type = types.listOf (
                  types.enum [
                    "core"
                    "signal"
                  ]
                );
                default = [ ];
                description = ''
                  Contract events not treated as service failure, written to the
                  `startd` property group.
                '';
              };

              manifest = mkOption {
                type = types.package;
                readOnly = true;
                description = "The rendered manifest, as a file in the store.";
              };
            };

            config = {
              name = mkOptionDefault name;
              bundleName = mkOptionDefault "nixbsd:${baseNameOf config.name}";
              fmri = "svc:/${config.name}:default";
              template.commonName = mkOptionDefault (baseNameOf config.name);
              manifest = pkgs.buildPackages.writeText "${baseNameOf config.name}.xml" (renderService config);

              propertyGroups.startd = {
                type = "framework";
                properties = {
                  duration.value = config.duration;
                }
                // optionalAttrs (config.ignoreError != [ ]) {
                  ignore_error.value = concatStringsSep "," config.ignoreError;
                };
              };
            };
          }
        )
      );
    };

    manifests = mkOption {
      type = types.package;
      readOnly = true;
      description = ''
        Directory of generated service manifests, laid out the way
        `/lib/svc/manifest` is: one XML file per service, at the path given by
        the service name.
      '';
    };
  };

  config = mkIf (config.init.backend == "illumos") {
    smf.manifests = manifestDir;
    system.build.smfManifests = manifestDir;

    # NOTE: the manifests svccfg(8) imports at boot really live in
    # /lib/svc/manifest, not /etc. Nothing in nixbsd manages /lib yet, and no
    # SMF implementation is packaged, so this only makes the manifests part of
    # the system closure and inspectable on the running system.
    environment.etc."svc/manifest".source = manifestDir;

    assertions = concatLists (
      mapAttrsToList (name: svc: [
        {
          assertion = svc.instances == { } -> svc.defaultInstance.enable;
          message = "smf.services.${name} declares no instances and no default instance, so it can never run.";
        }
      ]) config.smf.services
    );
  };
}
