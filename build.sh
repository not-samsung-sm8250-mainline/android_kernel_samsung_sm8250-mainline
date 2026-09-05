#!/usr/bin/env bash
set -e
SECONDS=0

TC_DIR="$(pwd)/tc/clang"
OUT_DIR="$(pwd)/out"
BOOT_DIR="$OUT_DIR/arch/arm64/boot"
ZIPNAME="r8q-mainline-$(date '+%Y%m%d')-$(git rev-parse --short HEAD)-r8q.zip"

export PATH="$TC_DIR/bin:$PATH"

if ! [ -d "$TC_DIR" ]; then
	echo "downloading clang..."
	mkdir -p "$TC_DIR"
	ASSET_URL=$(
		curl -fsSL https://api.github.com/repos/Neutron-Toolchains/clang-build-catalogue/releases/latest |
		jq -r '.assets[]
			| select(.name | endswith(".tar.zst"))
			| .browser_download_url' |
		head -n1
	)
	[ -z "$ASSET_URL" ] && { echo "no clang release found"; exit 1; }
	curl -L "$ASSET_URL" | tar --zstd -x -C "$TC_DIR" --strip-components=1
fi

mkdir -p out
./scripts/kconfig/merge_config.sh -m -O out arch/arm64/configs/defconfig arch/arm64/configs/r8q.config
make O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
make -j$(nproc --all) O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 Image.gz dtbs modules

[ -f "$BOOT_DIR/Image.gz" ] || { echo "Image.gz missing"; exit 1; }
[ -f "$BOOT_DIR/dts/qcom/sm8250-samsung-r8q.dtb" ] || { echo "r8q dtb missing"; exit 1; }

make O=out ARCH=arm64 LLVM=1 modules_install INSTALL_MOD_PATH="$(pwd)/mods" INSTALL_MOD_STRIP=1
rm -f mods/lib/modules/*/build mods/lib/modules/*/source

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
