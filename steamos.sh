#!/usr/bin/env bash
set -Eeuo pipefail

thisDir="$(dirname "$(readlink -f "$BASH_SOURCE")")"
source "$thisDir/scripts/.constants.sh" \
	--flags 'no-build' \
	-- \
	'[--no-build] <output-dir> [suite]' \
	'output'

eval "$dgetopt"
build=1
while true; do
	flag="$1"; shift
	dgetopt-case "$flag"
	case "$flag" in
		--no-build) build= ;; # for skipping "docker build"
		--) break ;;
		*) eusage "unknown flag '$flag'" ;;
	esac
done

outputDir="${1:-}"; shift || eusage 'missing output-dir'
suite="${1:-brewmaster}" # http://repo.steampowered.com/steamos/dists/

mkdir -p "$outputDir"
outputDir="$(readlink -f "$outputDir")"

securityArgs=(
	--cap-add SYS_ADMIN
	--cap-drop SETFCAP
)
if docker info | grep -q apparmor; then
	# AppArmor blocks mount :)
	securityArgs+=(
		--security-opt apparmor=unconfined
	)
fi

ver="$("$thisDir/scripts/debuerreotype-version")"
ver="${ver%% *}"
dockerImage="debuerreotype/debuerreotype:$ver"
[ -z "$build" ] || docker build -t "$dockerImage" "$thisDir"

steamDockerImage="$dockerImage-steamos"
[ -z "$build" ] || docker build -t "$steamDockerImage" - <<-EODF
	FROM $dockerImage
	# http://repo.steampowered.com/steamos/pool/main/v/valve-archive-keyring/?C=M;O=D
	RUN wget -O valve.deb 'http://repo.steampowered.com/steamos/pool/main/v/valve-archive-keyring/valve-archive-keyring_0.5+bsos3_all.deb' \\
		&& apt install -y ./valve.deb \\
		&& rm valve.deb
EODF

docker run \
	--rm \
	"${securityArgs[@]}" \
	--tmpfs /tmp:dev,exec,suid,noatime \
	-w /tmp \
	-e suite="$suite" \
	-e TZ='UTC' -e LC_ALL='C' \
	"$steamDockerImage" \
	bash -Eeuo pipefail -c '
		set -x

		mirror="http://repo.steampowered.com/steamos"

		dpkgArch="$(dpkg --print-architecture | awk -F- "{ print \$NF }")"

		exportDir="output"
		outputDir="$exportDir/steamos/$dpkgArch/$suite"

		debuerreotypeScriptsDir="$(dirname "$(readlink -f "$(which debuerreotype-init)")")"

		keyring="/usr/share/keyrings/valve-archive-keyring.gpg"

		mkdir -p "$outputDir"
		if wget -O "$outputDir/InRelease" "$mirror/dists/$suite/InRelease"; then
			gpgv \
				--keyring "$keyring" \
				--output "$outputDir/Release" \
				"$outputDir/InRelease"
		else
			wget -O "$outputDir/Release.gpg" "$mirror/dists/$suite/Release.gpg"
			wget -O "$outputDir/Release" "$mirror/dists/$suite/Release"
			gpgv \
				--keyring "$keyring" \
				"$outputDir/Release.gpg" \
				"$outputDir/Release"
		fi

		{
			debuerreotype-init --non-debian \
				--debootstrap-script /usr/share/debootstrap/scripts/jessie \
				--keyring "$keyring" \
				--include valve-archive-keyring \
				--exclude debian-archive-keyring \
				--no-merged-usr \
				rootfs "$suite" "$mirror"
			echo "deb $mirror $suite main contrib non-free" | tee rootfs/etc/apt/sources.list

			epoch="$(< rootfs/debuerreotype-epoch)"
			touch_epoch() {
				while [ "$#" -gt 0 ]; do
					local f="$1"; shift
					touch --no-dereference --date="@$epoch" "$f"
				done
			}

			debuerreotype-minimizing-config rootfs
			debuerreotype-apt-get rootfs update -qq
			debuerreotype-apt-get rootfs dist-upgrade -yqq

			# make a couple copies of rootfs so we can create other variants
			for variant in slim sbuild; do
				mkdir "rootfs-$variant"
				tar -cC rootfs . | tar -xC "rootfs-$variant"
			done

			# prefer iproute2 if it exists
			iproute=iproute2
			if ! debuerreotype-chroot rootfs apt-get install -qq -s iproute2 &> /dev/null; then
				# poor wheezy
				iproute=iproute
			fi
			debuerreotype-apt-get rootfs install -y --no-install-recommends iputils-ping $iproute

			debuerreotype-slimify rootfs-slim

			# this should match the list added to the "buildd" variant in debootstrap and the list installed by sbuild
			# https://anonscm.debian.org/cgit/d-i/debootstrap.git/tree/scripts/sid?id=706a45681c5bba5e062a9b02e19f079cacf2a3e8#n26
			# https://anonscm.debian.org/cgit/buildd-tools/sbuild.git/tree/bin/sbuild-createchroot?id=eace3d3e59e48d26eaf069d9b63a6a4c868640e6#n194
			fakeroot=fakeroot
			if [[ "$suite" == alchemist* ]]; then
				# poor alchemist
				fakeroot=
			fi
			debuerreotype-apt-get rootfs-sbuild install -y --no-install-recommends build-essential $fakeroot

			create_artifacts() {
				local targetBase="$1"; shift
				local rootfs="$1"; shift
				local suite="$1"; shift
				local variant="$1"; shift

				if [ "$variant" != "sbuild" ]; then
					debuerreotype-tar "$rootfs" "$targetBase.tar.xz"
				else
					# sbuild needs "deb-src" entries
					debuerreotype-chroot "$rootfs" sed -ri -e "/^deb / p; s//deb-src /" /etc/apt/sources.list

					# APT has odd issues with "Acquire::GzipIndexes=false" + "file://..." sources sometimes
					# (which are used in sbuild for "--extra-package")
					#   Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
					#   ...
					#   E: Failed to fetch store:/var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages  Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
					rm -f "$rootfs/etc/apt/apt.conf.d/docker-gzip-indexes"
					# TODO figure out the bug and fix it in APT instead /o\

					# schroot is picky about "/dev" (which is excluded by default in "debuerreotype-tar")
					# see https://github.com/debuerreotype/debuerreotype/pull/8#issuecomment-305855521
					debuerreotype-tar --include-dev "$rootfs" "$targetBase.tar.xz"
				fi
				du -hsx "$targetBase.tar.xz"

				sha256sum "$targetBase.tar.xz" | cut -d" " -f1 > "$targetBase.tar.xz.sha256"
				touch_epoch "$targetBase.tar.xz.sha256"

				debuerreotype-chroot "$rootfs" dpkg-query -W > "$targetBase.manifest"
				echo "$epoch" > "$targetBase.debuerreotype-epoch"
				touch_epoch "$targetBase.manifest" "$targetBase.debuerreotype-epoch"

				for f in debian_version os-release apt/sources.list; do
					targetFile="$targetBase.$(basename "$f" | sed -r "s/[^a-zA-Z0-9_-]+/-/g")"
					cp "$rootfs/etc/$f" "$targetFile"
					touch_epoch "$targetFile"
				done
			}

			for rootfs in rootfs*/; do
				rootfs="${rootfs%/}" # "rootfs", "rootfs-slim", ...

				du -hsx "$rootfs"

				variant="${rootfs#rootfs}" # "", "-slim", ...
				variant="${variant#-}" # "", "slim", ...

				variantDir="$outputDir/$variant"
				mkdir -p "$variantDir"

				targetBase="$variantDir/rootfs"

				create_artifacts "$targetBase" "$rootfs" "$suite" "$variant"
			done
		} >&2

		tar -cC "$exportDir" .
	' | tar -xvC "$outputDir"
