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

  # Historical note: a `<dependency>` holding more than one `<service_fmri>`
  # used to kill svc.configd during `svccfg import`. The import died with
  #
  #     svccfg: Could not delete svc:/TEMP/<service> (repository connection broken).
  #
  # which is ECONNABORTED from the door call: configd had taken SIGSEGV, so its
  # own error paths never ran. The repository was left incomplete and svc.startd
  # then put everything into maintenance. That message is the only trace the
  # failure leaves behind, so it is recorded here for whoever greps for it.
  #
  # The cause, read out of configd's core -- it writes one as
  # `core.svc.configd.<time>.<pid>` in its own cwd, via
  # `core_set_process_path` at cmd/svc/configd/configd.c:659, which as root is
  # `/`. The faulting thread was
  #
  #     client_switcher -> tx_commit -> rc_tx_commit -> object_tx_commit
  #       -> tx_process_cmds -> backend_tx_run_update
  #       -> sqlite_exec_vprintf -> sqlite_vmprintf -> base_vprintf -> vxprintf
  #
  # dying on the `'%q'` argument of the per-value INSERT into `value_tbl`,
  # with a pointer exactly 2^32 below the buffer it should have named. That
  # pointer is built one line above the INSERT, at
  # cmd/svc/configd/object.c:324:
  #
  #     v = (uint32_t *)((caddr_t)str + TX_SIZE(*v));
  #
  # `TX_SIZE(x)` is `P2ROUNDUP((x), sizeof (uint32_t))`
  # (common/svc/repcache_protocol.h:765), and `P2ROUNDUP(x, align)` is
  # `(-(-(x) & -(align)))` (uts/common/sys/sysmacros.h:268). With `x` a
  # `uint32_t` and `align` a `size_t`, `-(x)` is evaluated in 32 bits and then
  # *zero*-extended to 64 before the mask, so the closing negation landed in
  # the top half: `TX_SIZE((uint32_t)27)` was 0xffffffff0000001c, not 28. Every
  # other TX_SIZE call site assigns the result back to a 32-bit variable and
  # so truncated the damage away; this one fed it straight into pointer
  # arithmetic. It was reached only from the second iteration of the value
  # loop onwards, which is exactly why one `<service_fmri>` was fine and two
  # were fatal.
  #
  # It was 64-bit-only -- with a 32-bit `size_t` both halves agree -- which is
  # why upstream, where cmd/svc/configd is still built 32-bit, never hit it.
  #
  # It is fixed in our illumos tree: patches 0068 and 0069 under
  # pkgs/os-specific/illumos/patches/ cast the operand to `size_t` at both
  # affected call sites. This module therefore no longer splits a dependency
  # into one block per FMRI. That workaround could not represent `require_any`
  # or `exclude_all` at all -- you cannot split "any one of these" into
  # separate dependencies without changing its meaning -- and both groupings
  # are usable again.

  fmriNodes = fmris: map (f: leaf "service_fmri" { value = f; }) fmris;

  dependencyNode =
    name: d:
    elem "dependency" {
      inherit name;
      inherit (d) grouping;
      restart_on = d.restartOn;
      inherit (d) type;
    } (fmriNodes d.fmris);

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
    mapAttrsToList dependencyNode x.dependencies
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

  # Build-time validation of the generated manifests.
  #
  # What this is *not*: `svccfg validate`. That runs libscf's template engine
  # -- property groups checked against the types their templates declare,
  # required properties, cardinalities, value constraints -- and it needs a
  # bound repository handle, because template validation composes a manifest
  # against the templates already in the repository (`tmpl_validate_bundle`
  # calls `lscf_prep_hndl`, cmd/svc/svccfg/svccfg_tmpl.c:4017). A repository
  # handle means a running svc.configd, and svc.configd is an illumos binary
  # that speaks doors. Nothing can run it on the Linux machine that builds
  # this derivation, so the semantic half of validation cannot happen here. It
  # happens where the manifests are imported, at boot, in ../illumos-smf.nix.
  #
  # What this *is*: DTD validation against the very DTD svccfg itself parses
  # with -- cmd/svc/dtd/service_bundle.dtd.1, shipped in `illumos.svccfg`.
  # That is worth having on its own, because the failure mode this renderer
  # actually has is structural: an element the DTD does not declare, a
  # misspelled attribute, or children in the wrong order, the DTD's content
  # models being sequences and not choices. Each of those makes `svccfg
  # import` answer "Document is not valid" at boot and then import *nothing at
  # all*, so the symptom is a system with no services rather than a complaint
  # about the one manifest at fault.
  #
  # `--valid --path <dtddir>` rather than `--dtdvalid <file>`: the manifests
  # carry a DOCTYPE naming the illumos system path
  # /usr/share/lib/xml/dtd/service_bundle.dtd.1, and `--path` is what lets
  # libxml2 resolve that by base name out of the store. As of libxml2 2.15
  # `--dtdvalid` reports only "does not validate", where `--valid` still
  # prints the offending element and line.
  dtdPackage = pkgs.illumos.svccfg or null;

  # `or null` throughout this file's neighbours for the same reason: the
  # module has to stay evaluable against a nixpkgs that has not packaged
  # svccfg yet. Without the DTD there is simply no check.
  validateManifests = optionalString (dtdPackage != null) ''
    echo "smf-manifests: DTD-validating $(find $out -name '*.xml' | wc -l) manifests"
    failed=
    for manifest in $(find $out -name '*.xml' | sort); do
      ${lib.getBin pkgs.buildPackages.libxml2}/bin/xmllint --noout --nonet \
        --path ${dtdPackage}/share/lib/xml/dtd --valid "$manifest" \
        || failed="$failed $manifest"
    done
    if [ -n "$failed" ]; then
      echo "smf-manifests: invalid against service_bundle.dtd.1:$failed" >&2
      exit 1
    fi
  '';

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
    + validateManifests
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
