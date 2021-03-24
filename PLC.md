# Use of the Plutus compiler (PLC)

To use the Plutus compiler you need to follow the next steps:

1. Install `nix` with the command `curl -L https://nixos.org/nix/install | sh`  (actually I had to install curl first)
2. Install `git` and download the plutus repository
3. (This step is very important) Create the folder `/etc/nix`  and the file `/etc/nix/nix.conf` with the following content:
```
substituters        = https://hydra.iohk.io https://iohk.cachix.org https://cache.nixos.org/
trusted-public-keys = hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ= iohk.cachix.org-1:DpRUyj7h7V830dp/i6Nti+NEO2/nhblbov/8MW7Rqoo= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
```
4. Use the command `nix build -f default.nix plutus.haskell.packages.plutus-core` to build the package and `nix build -f default.nix plutus.haskell.packages.plutus-core.components.exes.plc` to build the binary file, this last command creates a new folder called `result/bin` containing the binary file.

Note: Looks like 10 GB (default space configuration in VirtualBox) of disk is not enough to build it, I had to increase it to 50 GB, but only 15 GB are needed
