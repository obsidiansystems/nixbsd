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

  esc = escapeXML;

  attr = name: value: optionalString (value != null) " ${name}='${esc (toString value)}'";

  # <propval>/<property> ------------------------------------------------------

  # `toString true` is "1", which is not a valid SMF boolean.
  fmtValue = v: if isBool v then boolToString v else toString v;

  renderPropval =
    indent: name: p:
    if p.values == null then
      "${indent}<propval name='${esc name}' type='${p.type}' value='${esc (fmtValue p.value)}'/>\n"
    else
      ''
        ${indent}<property name='${esc name}' type='${p.type}'>
        ${indent}  <${p.type}_list>
        ${
          concatMapStrings (v: "${indent}    <value_node value='${esc (fmtValue v)}'/>\n") p.values
        }${indent}  </${p.type}_list>
        ${indent}</property>
      '';

  renderPropertyGroup = indent: name: pg: ''
    ${indent}<property_group name='${esc name}' type='${esc pg.type}'>
    ${concatStrings (mapAttrsToList (renderPropval "${indent}  ") pg.properties)}${indent}</property_group>
  '';

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

  renderDependency =
    indent: name: d:
    let
      one = suffix: f: ''
        ${indent}<dependency name='${esc (name + suffix)}' grouping='${d.grouping}' restart_on='${d.restartOn}' type='${esc d.type}'>
        ${indent}  <service_fmri value='${esc f}'/>
        ${indent}</dependency>
      '';
    in
    if splittableGrouping d.grouping && length d.fmris > 1 then
      concatStrings (imap0 (i: f: one "-${toString i}" f) d.fmris)
    else
      ''
        ${indent}<dependency name='${esc name}' grouping='${d.grouping}' restart_on='${d.restartOn}' type='${esc d.type}'>
        ${
          concatMapStrings (f: "${indent}  <service_fmri value='${esc f}'/>\n") d.fmris
        }${indent}</dependency>
      '';

  renderDependent = indent: name: d: ''
    ${indent}<dependent name='${esc name}' grouping='${d.grouping}' restart_on='${d.restartOn}'>
    ${
      concatMapStrings (f: "${indent}  <service_fmri value='${esc f}'/>\n") d.fmris
    }${indent}</dependent>
  '';

  # <method_context> ---------------------------------------------------------

  hasMethodContext =
    mc:
    mc.user != null
    || mc.workingDirectory != null
    || mc.project != null
    || mc.resourcePool != null
    || mc.environment != { };

  renderMethodContext =
    indent: mc:
    optionalString (hasMethodContext mc) (
      let
        credential = optionalString (mc.user != null) (
          "${indent}  <method_credential${attr "user" mc.user}${attr "group" mc.group}"
          + "${attr "supp_groups" (
            if mc.supplementaryGroups == [ ] then null else concatStringsSep "," mc.supplementaryGroups
          )}"
          + "${attr "privileges" mc.privileges}${attr "limit_privileges" mc.limitPrivileges}/>\n"
        );
        env = optionalString (mc.environment != { }) ''
          ${indent}  <method_environment>
          ${
            concatStrings (
              mapAttrsToList (n: v: "${indent}    <envvar name='${esc n}' value='${esc v}'/>\n") mc.environment
            )
          }${indent}  </method_environment>
        '';
      in
      ''
        ${indent}<method_context${attr "working_directory" mc.workingDirectory}${attr "project" mc.project}${attr "resource_pool" mc.resourcePool}>
        ${credential}${env}${indent}</method_context>
      ''
    );

  # <exec_method> ------------------------------------------------------------

  renderExecMethod =
    indent: name: m:
    let
      open = "${indent}<exec_method type='${m.type}' name='${esc name}' exec='${esc m.exec}' timeout_seconds='${toString m.timeoutSeconds}'";
      inner = renderMethodContext "${indent}  " m.methodContext;
    in
    if inner == "" then "${open}/>\n" else "${open}>\n${inner}${indent}</exec_method>\n";

  # <template> ---------------------------------------------------------------

  renderTemplate =
    indent: t:
    let
      documentation = optionalString (t.manpages != [ ] || t.docLinks != [ ]) ''
        ${indent}  <documentation>
        ${
          concatMapStrings (
            m:
            "${indent}    <manpage title='${esc m.title}' section='${esc m.section}' manpath='${esc m.manpath}'/>\n"
          ) t.manpages
        }${
          concatMapStrings (
            l: "${indent}    <doc_link name='${esc l.name}' uri='${esc l.uri}'/>\n"
          ) t.docLinks
        }${indent}  </documentation>
      '';
    in
    ''
      ${indent}<template>
      ${indent}  <common_name>
      ${indent}    <loctext xml:lang='C'>${esc t.commonName}</loctext>
      ${indent}  </common_name>
      ${
        optionalString (t.description != null) ''
          ${indent}  <description>
          ${indent}    <loctext xml:lang='C'>${esc t.description}</loctext>
          ${indent}  </description>
        ''
      }${documentation}${indent}</template>
    '';

  # <instance> ---------------------------------------------------------------

  renderInstance = indent: name: inst: ''
    ${indent}<instance name='${esc name}' enabled='${boolToString inst.enabled}'>
    ${concatStrings (mapAttrsToList (renderDependency "${indent}  ") inst.dependencies)}${concatStrings (mapAttrsToList (renderDependent "${indent}  ") inst.dependents)}${renderMethodContext "${indent}  " inst.methodContext}${concatStrings (mapAttrsToList (renderExecMethod "${indent}  ") inst.execMethods)}${concatStrings (mapAttrsToList (renderPropertyGroup "${indent}  ") inst.propertyGroups)}${indent}</instance>
  '';

  # <service> / <service_bundle> ---------------------------------------------

  renderService = svc: ''
    <?xml version='1.0'?>
    <!DOCTYPE service_bundle SYSTEM '/usr/share/lib/xml/dtd/service_bundle.dtd.1'>
    <!-- Generated by nixbsd; do not edit. -->
    <service_bundle type='manifest' name='${esc svc.bundleName}'>
      <service name='${esc svc.name}' type='${svc.type}' version='${toString svc.version}'>
    ${optionalString (svc.defaultInstance.enable) "    <create_default_instance enabled='${boolToString svc.defaultInstance.enabled}'/>\n"}${optionalString svc.singleInstance "    <single_instance/>\n"}${concatStrings (mapAttrsToList (renderDependency "    ") svc.dependencies)}${concatStrings (mapAttrsToList (renderDependent "    ") svc.dependents)}${renderMethodContext "    " svc.methodContext}${concatStrings (mapAttrsToList (renderExecMethod "    ") svc.execMethods)}${concatStrings (mapAttrsToList (renderPropertyGroup "    ") svc.propertyGroups)}${concatStrings (mapAttrsToList (renderInstance "    ") svc.instances)}    <stability value='${svc.stability}'/>
    ${renderTemplate "    " svc.template}  </service>
    </service_bundle>
  '';

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
