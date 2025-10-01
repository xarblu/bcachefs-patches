# THIS REPOSITORY IS NOT AFFILIATED WITH OR ENDORSED BY BCACHEFS

## Why?

Bcachefs wasn't updated in the upstream since 6.16 and finally removed in the 6.18 merge window.
Because I'm not a fan of DKMS these patches aim to bring the latest bcachefs from https://evilpiepirate.org/git/bcachefs.git/
back into the regular kernel tree.

Since I'm on Gentoo and already building my own customized/patched kernel anyways might as well include bcachefs.

## How?

Essentially these are the steps to create a patch:

- Grab latest tagged release of `bcachefs-tools`
- Grab the commit in `.bcachefs_revision` from the `bcachefs-tools` repo  
  (contains the commit in Kent's bcachefs tree the DKMS is based on)
- `git diff` the upstream kernel at tag `vX.Y` with said bcachefs commit

For details check out the `patch-generator.sh` script in this repo.

## For Gentoo users

I maintain a port of the [CachyOS Kernel](https://github.com/CachyOS/linux-cachyos) in [my overlay](https://github.com/xarblu/xarblu-overlay)
which optionally includes these bcachefs patches.

To use it enable the repo:

```bash
# eselect repository enable xarblu-overlay
```

Then enable `USE=bcachefs` for `sys-kernel/cachyos-kernel`:

```bash
# echo sys-kernel/cachyos-kernel bcachefs > /etc/portage/package.use/cachyos_kernel_bcachefs
```

And finally emerge the kernel:

```bash
# emerge --ask sys-kernel/cachyos-kernel
```
