# BuildBuddy RBE fix for LineageOS 21

## Apply the patch

From the tree root:

```bash
./tutorial/scripts/patch_rewrapper.sh
```

## Set up your build shell

```bash
unset RBE_DIR
unset RBE_service_no_auth
export USE_RBE=1
export RBE_service=remote.buildbuddy.io:443
export RBE_remote_headers=x-buildbuddy-api-key=YOUR_API_KEY
export RBE_use_rpc_credentials=false
```

If `RBE_service_no_auth=true` is set in your `~/.zshrc` / `~/.bashrc`,
delete it.

## Build

```bash
source build/envsetup.sh
lunch lineage_<device>-ap2a-userdebug
m
```
