{
  description = "SuperMicro Fan Control";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };


  outputs =
    { self
    , nixpkgs
    , uv2nix
    , pyproject-nix
    , pyproject-build-systems
    , ...
    }:
    let
      inherit (nixpkgs) lib;
      version = "4.0.0";

      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      repo = pkgs.fetchFromGitHub {
        owner = "petersulyok";
        repo = "smfc";
        rev = "v${version}";
        sha256 = "sha256-qV91dQlEvSMcw+YbX6TqpDiifK1rP76tvv2B0xFLYUU=";
      };

      # Load a uv workspace from a workspace root.
      # Uv2nix treats all uv projects as workspace projects.
      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = repo; };

      # Create package overlay from workspace.
      overlay = workspace.mkPyprojectOverlay {
        # Prefer prebuilt binary wheels as a package source.
        # Sdists are less likely to "just work" because of the metadata missing from uv.lock.
        # Binary wheels are more likely to, but may still require overrides for library dependencies.
        sourcePreference = "wheel"; # or sourcePreference = "sdist";
        # Optionally customise PEP 508 environment
        # environ = {
        #   platform_release = "5.10.65";
        # };
      };

      # Extend generated overlay with build fixups
      #
      # Uv2nix can only work with what it has, and uv.lock is missing essential metadata to perform some builds.
      # This is an additional overlay implementing build fixups.
      # See:
      # - https://pyproject-nix.github.io/uv2nix/FAQ.html

      inherit (pkgs) stdenv;

      # An overlay of build fixups & test additions.m
      pyprojectOverrides = final: prev: {
        smfc = prev.smfc.overrideAttrs (old: {

          passthru = old.passthru // {
            # Put all tests in the passthru.tests attribute set.
            # Nixpkgs also uses the passthru.tests mechanism for ofborg test discovery.
            #
            # For usage with Flakes we will refer to the passthru.tests attributes to construct the flake checks attribute set.
            tests =
              let
                # Construct a virtual environment with only the dev dependency-group enabled for testing.
                virtualenv = final.mkVirtualEnv "smfc-pytest-env" {
                  smfc = [ "dev" ];
                };

              in
              (old.tests or { })
                // {
                pytest = stdenv.mkDerivation {
                  name = "${final.smfc.name}-pytest";
                  inherit (final.smfc) src;
                  nativeBuildInputs = [
                    virtualenv
                  ];
                  dontConfigure = true;

                  # Because this package is running tests, and not actually building the main package
                  # the build phase is running the tests.
                  #
                  # In this particular example we also output a HTML coverage report, which is used as the build output.
                  buildPhase = ''
                    runHook preBuild
                    pytest --cov tests --cov-report html
                    runHook postBuild
                  '';

                  # Install the HTML coverage report into the build output.
                  #
                  # If you wanted to install multiple test output formats such as TAP outputs
                  # you could make this derivation a multiple-output derivation.
                  #
                  # See https://nixos.org/manual/nixpkgs/stable/#chap-multiple-output for more information on multiple outputs.
                  installPhase = ''
                    runHook preInstall
                    mv htmlcov $out
                    runHook postInstall
                  '';
                };

              };
          };
        });
      };


      # Use Python 3.12 from nixpkgs
      python = pkgs.python312;

      # Construct package set
      pythonSet =
        # Use base package set from pyproject.nix builders
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope
          (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.default
              overlay
              pyprojectOverrides
            ]
          );

    in
    {
      # Package a virtual environment as our main application.
      #
      # Enable no optional dependencies for production build.
      packages.x86_64-linux = {
        default =
          let
            inherit (pkgs.callPackages pyproject-nix.build.util { }) mkApplication;
          in
          mkApplication {
            venv = pythonSet.mkVirtualEnv "smfc-env" workspace.deps.default;
            package = pythonSet.smfc;
          };
      };

      # Make hello runnable with `nix run`
      apps.x86_64-linux = {
        default = {
          type = "app";
          program = "${self.packages.x86_64-linux.default}/bin/smfc";
        };
      };

      # checks.x86_64-linux = {
      #   inherit (pythonSet.smfc.passthru.tests) pytest;
      # };
      #
      nixosModules = {
        default = { config, lib, pkgs, ... }: with lib; let cfg = config.services.smfc; in {
          options.services.smfc = {
            enable = mkEnableOption "supermicro fan control service";
            smartmontools =
              {
                enable = mkEnableOption "enable smartmontools support for SMFC" // {
                  default = true;
                };
                package = mkOption { type = types.package; default = pkgs.smartmontools; };
              };
            nvidia-smi =
              {
                enable = mkEnableOption "enable nvidia-smi support for SMFC";

                package = mkOption { type = types.package; default = pkgs.nvidia-smi; };
              };
            logLevel = mkOption {
              type = types.enum [ "none" "error" "config" "info" "debug" ];
              default = 1;
              description = "Log level for SMFC";
            };
            logOutput = mkOption {
              type = types.enum [ "stdout" "stderr" "syslog" ];
              default = "syslog";
              description = "Log output for SMFC";
            };
            recovery = mkOption
              {
                type = types.bool;
                default = true;
                description = "Enable fan speed recovery at startup";
              };
            zones =
              let
                zoneOptions = {
                  enabled = mkOption {
                    type = types.bool;
                    description = "Enable fan speed control for this zone";
                  };
                  ipmi_zone = mkOption {
                    type = types.listOf types.ints.unsigned;
                    description = "List of IPMI fan zones to control";
                  };
                  temp_calc = mkOption
                    {
                      type = types.enum [ 0 1 2 ];
                      default = 1;
                      description = "Temperature calculation mode (0=minimum, 1=average, 2=maximum)";
                    };
                  steps = mkOption {
                    type = types.ints.positive;
                    description = "Number of fan speed steps";
                  };
                  sensitivity = mkOption {
                    type = types.number;
                    description = "Threshold before the fan controller reacts (degrees C)";
                  };
                  polling = mkOption {
                    type = types.ints.positive;
                    description = "Temperature polling interval (seconds)";
                  };
                  min_temp = mkOption {
                    type = types.number;
                    description = "Minimum temperature for the fan curve (degrees C)";
                  };
                  max_temp = mkOption {
                    type = types.number;
                    description = "Maximum temperature for the fan curve (degrees C)";
                  };
                  min_level = mkOption {
                    type = types.ints.between 0 100;
                    description = "Minimum fan speed level (percentage)";
                  };
                  max_level = mkOption {
                    type = types.ints.between 0 100;
                    description = "Maximum fan speed level (percentage)";
                  };
                };
                hdZoneOptions = {
                  hd_names = mkOption {
                    type = types.listOf types.path;
                    description = "List of hard drive names. These must be specified in `/dev/disk/by-id/` form.";
                  };
                  standby_guard_enabled = mkOption {
                    type = types.bool;
                    description = "Standby guard feature for RAID arrays (bool; default=0)";
                    default = false;
                  };
                  standby_hd_limit = mkOption {
                    type = types.int;
                    description = "Number of HDs already in STANDBY state before the full RAID array will be forced to it";
                    default = 1;
                  };
                };
              in
              {
                cpu = mkOption {
                  type = types.submodule {
                    options = zoneOptions;
                  };
                  description = "Configuration for the CPU fan zone";
                  default = {
                    enabled = true;
                    ipmi_zone = [ 0 ];
                    temp_calc = 1;
                    steps = 6;
                    polling = 2;
                    sensitivity = 3.0;
                    min_temp = 30.0;
                    max_temp = 60.0;
                    min_level = 35;
                    max_level = 100;
                  };
                };
                hd =
                  mkOption {
                    type = types.submodule {
                      options = (zoneOptions // hdZoneOptions);
                    };
                    description = "Configuration for the HD fan zone";
                    default = {
                      enabled = cfg.smartmontools.enable;
                      ipmi_zone = [ 1 ];
                      temp_calc = 1;
                      steps = 4;
                      polling = 10;
                      sensitivity = 2.0;
                      min_temp = 32.0;
                      max_temp = 46.0;
                      min_level = 35;
                      max_level = 100;
                    };
                  };
                gpu = mkOption
                  {
                    type = types.submodule {
                      options = zoneOptions // {
                        gpu_device_ids = mkOption
                          {
                            type = types.listOf types.ints.unsigned;
                            description = "GPU device IDs. These are indices in nvidia-smi temperature report.";
                            default = [ 0 ];
                          };
                      };
                    };
                    description = "Configuration for GPU zone";
                    default = {
                      enabled = cfg.nvidia-smi.enable;
                      ipmi_zone = [ 1 ];
                      temp_calc = 1;
                      steps = 5;
                      polling = 2;
                      sensitivity = 2.0;
                      min_temp = 40.0;
                      max_temp = 70.0;
                      min_level = 35;
                      max_level = 100;
                    };

                  };
              };
          };

          config = mkIf cfg.enable
            {
              environment.etc."/smfc/smfc.conf".source =
                let
                  mkValueString = v:
                    if v == true then "1"
                    else if v == false then "0"
                    else if isList v then builtins.concatStringsSep "," (map (x: toString x) v)
                    else generators.mkValueStringDefault { } v;
                in
                generators.toINI
                  {
                    mkKeyValue = generators.mkKeyValueDefault { inherit mkValueString; } "=";
                  }
                  {
                    "Ipmi" =
                      {
                        command = "${pkgs.ipmitool}/bin/ipmitool";
                      };
                    "CPU zone" = cfg.zones.cpu;
                    "HDD zone" = cfg.zones.hd;
                    "GPU zone" = cfg.zones.gpu;
                  };
              systemd.services.sfmcd =
                {
                  description = "SuperMicro Fan Control Daemon";
                  wantedBy = [ "multi-user.target" ];
                  path = mkMerge [
                    (with pkgs; [ ipmitool self.packages.x86_64-linux.default ])
                  ];
                  script =
                    let
                      logLevels = {
                        none = "0";
                        error = "1";
                        config = "2";
                        info = "3";
                        debug = "4";
                      };
                      logLevel = attrsets.getAttr cfg.logLevel logLevels;
                      logOutputs = {
                        stdout = "0";
                        stderr = "1";
                        syslog = "2";
                      };
                      logOutput = attrsets.getAttr cfg.logOutput logOutputs;
                    in
                    ''
                      ${self.packages.x86_64-linux.default}/bin/smfc \
                        -l ${logLevel} \
                        -o ${logOutput} \
                        -c /etc/smfc/smfc.conf
                    '';
                  serviceConfig = {
                    # DeviceAllow = "/dev/ipmi*";
                  };
                };
            };
        };
      };
    };
}
