#!/usr/bin/env bash
set -e
SECONDS=0

TC_DIR="${KERNEL_CLANG_DIR:-$(pwd)/tc/clang}"
OUT_DIR="$(pwd)/out"
BOOT_DIR="$OUT_DIR/arch/arm64/boot"
ZIPNAME="r8q-mainline-$(date '+%Y%m%d')-$(git rev-parse --short HEAD)-r8q.zip"

# Keep standalone CI builds reproducible instead of following a moving release.
NEUTRON_CLANG_URL="${NEUTRON_CLANG_URL:-https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/06092026/neutron-clang-06092026.tar.zst}"
NEUTRON_CLANG_SHA256="${NEUTRON_CLANG_SHA256:-531083928c8e37f6b31e324dbfd0b5a8323f989b1c57ff2c1368b889b5b1bd30}"

export PATH="$TC_DIR/bin:$PATH"


if ! [ -x "$TC_DIR/bin/clang" ]; then
	echo "downloading clang..."
	mkdir -p "$TC_DIR"
	ARCHIVE="$(mktemp)"
	trap 'rm -f "$ARCHIVE"' EXIT
	curl -fL "$NEUTRON_CLANG_URL" -o "$ARCHIVE"
	printf '%s  %s\n' "$NEUTRON_CLANG_SHA256" "$ARCHIVE" | sha256sum -c -
	tar --zstd -xf "$ARCHIVE" -C "$TC_DIR" --strip-components=1
	rm -f "$ARCHIVE"
	trap - EXIT
fi

mkdir -p out
./scripts/kconfig/merge_config.sh -m -O out arch/arm64/configs/defconfig arch/arm64/configs/r8q.config
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
for required_config in \
	CONFIG_FS_ENCRYPTION=y \
	CONFIG_FS_ENCRYPTION_INLINE_CRYPT=y \
	CONFIG_DRM_SIMPLEDRM=y \
	CONFIG_DRM_MSM=m \
	CONFIG_DM_DEFAULT_KEY=y; do
	if ! grep -qx "$required_config" out/.config; then
		echo "Missing required kernel config: $required_config" >&2
		exit 1
	fi
done

make -j$(nproc --all) O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 Image.gz dtbs modules

if [ "${RUN_DTBS_CHECK:-0}" = 1 ]; then
	make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 dtbs_check
fi

[ -f "$BOOT_DIR/Image.gz" ] || { echo "Image.gz missing"; exit 1; }
[ -f "$BOOT_DIR/dts/qcom/sm8250-samsung-r8q.dtb" ] || { echo "r8q dtb missing"; exit 1; }

make O=out ARCH=arm64 LLVM=1 modules_install INSTALL_MOD_PATH="$(pwd)/mods" INSTALL_MOD_STRIP=1
rm -f mods/lib/modules/*/build mods/lib/modules/*/source
modules_dep_found=0
for modules_dep in mods/lib/modules/*/modules.dep; do
	if [ -f "$modules_dep" ]; then
		modules_dep_found=1
		break
	fi
done
[ "$modules_dep_found" -eq 1 ] || {
	echo "modules.dep missing after modules_install" >&2
	exit 1
}

rm -rf pkg && mkdir pkg
cp "$BOOT_DIR/Image.gz" pkg/
cp "$BOOT_DIR/dts/qcom/sm8250-samsung-r8q.dtb" pkg/
cp out/.config pkg/kernel.config
cp out/include/config/kernel.release pkg/ 2>/dev/null || true
tar -C mods -czf pkg/modules.tar.gz .
rm -rf mods

cd pkg
zip -r9 "../$ZIPNAME" *
cd ..

echo "done in $((SECONDS / 60))m $((SECONDS % 60))s: $ZIPNAME"
