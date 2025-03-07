# Copyright 1999-2018 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2

EAPI=7

CROS_WORKON_PROJECT="flatcar/grub"
CROS_WORKON_REPO="https://github.com"
GRUB_AUTOGEN=1  # We start from Git, so always autogen.

if [[ ${PV} == 9999 ]]; then
	KEYWORDS="~amd64 ~arm64 ~x86"
else
	CROS_WORKON_COMMIT="ba40c9d246602646b22b0d190f260f2d98c0351b"  # flatcar-master
	KEYWORDS="amd64 arm64 x86"
fi
inherit cros-workon

if [[ -n ${GRUB_AUTOGEN} ]]; then
	PYTHON_COMPAT=( python3_{6..11} )
	WANT_LIBTOOL=none
	inherit autotools python-any-r1
fi

inherit autotools bash-completion-r1 flag-o-matic multibuild pax-utils toolchain-funcs
DEJAVU=dejavu-sans-ttf-2.37
UNIFONT=unifont-9.0.06
SRC_URI+=" fonts? ( mirror://gnu/unifont/${UNIFONT}/${UNIFONT}.pcf.gz )
	themes? ( mirror://sourceforge/dejavu/${DEJAVU}.zip )"

DESCRIPTION="GNU GRUB boot loader"
HOMEPAGE="https://www.gnu.org/software/grub/"

# Includes licenses for dejavu and unifont
LICENSE="GPL-3 fonts? ( GPL-2-with-font-exception ) themes? ( BitstreamVera )"
SLOT="2/${PVR}"
IUSE="debug device-mapper doc efiemu +fonts mount multislot nls static sdl test +themes truetype libzfs"

GRUB_ALL_PLATFORMS=( coreboot efi-32 efi-64 emu ieee1275 loongson multiboot qemu qemu-mips pc uboot xen xen-32 )
GRUB_ALL_PLATFORMS+=( arm64 )  # Tack on arm64 for pulling in the cross-compiler.
IUSE+=" ${GRUB_ALL_PLATFORMS[@]/#/grub_platforms_}"

REQUIRED_USE="
	grub_platforms_coreboot? ( fonts )
	grub_platforms_qemu? ( fonts )
	grub_platforms_ieee1275? ( fonts )
	grub_platforms_loongson? ( fonts )
"

# os-prober: Used on runtime to detect other OSes
# xorriso (dev-libs/libisoburn): Used on runtime for mkrescue
RDEPEND="
	app-arch/xz-utils
	>=sys-libs/ncurses-5.2-r5
	debug? (
		sdl? ( media-libs/libsdl )
	)
	device-mapper? ( >=sys-fs/lvm2-2.02.45 )
	libzfs? ( sys-fs/zfs )
	mount? ( sys-fs/fuse )
	truetype? ( media-libs/freetype:2= )
	ppc? ( sys-apps/ibm-powerpc-utils sys-apps/powerpc-utils )
	ppc64? ( sys-apps/ibm-powerpc-utils sys-apps/powerpc-utils )
"
DEPEND="${RDEPEND}
	${PYTHON_DEPS}
	app-misc/pax-utils
	sys-devel/flex
	sys-devel/bison
	sys-apps/help2man
	sys-apps/texinfo
	grub_platforms_arm64? ( cross-aarch64-cros-linux-gnu/gcc )
	static? (
		app-arch/xz-utils[static-libs(+)]
		truetype? (
			app-arch/bzip2[static-libs(+)]
			media-libs/freetype[static-libs(+)]
			sys-libs/zlib[static-libs(+)]
		)
	)
	test? (
		app-admin/genromfs
		app-arch/cpio
		app-arch/lzop
		grub_platforms_efi-64? ( app-emulation/qemu[qemu_softmmu_targets_x86_64] )
		grub_platforms_pc? ( app-emulation/qemu[qemu_softmmu_targets_i386] )
		grub_platforms_arm64? ( app-emulation/qemu[qemu_softmmu_targets_aarch64] )
		dev-libs/libisoburn
		sys-apps/miscfiles
		sys-block/parted
		sys-fs/squashfs-tools[lzo,xz]
	)
	themes? (
		app-arch/unzip
		media-libs/freetype:2
	)
"
RDEPEND+="
	kernel_linux? (
		grub_platforms_efi-32? ( sys-boot/efibootmgr )
		grub_platforms_efi-64? ( sys-boot/efibootmgr )
	)
	!multislot? ( !sys-boot/grub:0 !sys-boot/grub-static )
	nls? ( sys-devel/gettext )
"

DEPEND+=" !!=media-libs/freetype-2.5.4"

RESTRICT="strip !test? ( test )"

QA_EXECSTACK="usr/bin/grub*-emu* usr/lib/grub/*"
QA_WX_LOAD="usr/lib/grub/*"
QA_MULTILIB_PATHS="usr/lib/grub/.*"

PATCHES=(
	"${FILESDIR}/${PN}-2.02-binutils-2.36-x86-used-note.patch"
	"${FILESDIR}/${PN}-2.02-configure-specify-gettext-version.patch"
)

src_unpack() {
	cros-workon_src_unpack
	default
}

src_prepare() {
	default

	sed -i -e /autoreconf/d autogen.sh || die

	if use multislot; then
		# fix texinfo file name, bug 416035
		sed -i -e 's/^\* GRUB:/* GRUB2:/' -e 's/(grub)/(grub2)/' docs/grub.texi || die
	fi

	# Nothing in Gentoo packages 'american-english' in the exact path
	# wanted for the test, but all that is needed is a compressible text
	# file, and we do have 'words' from miscfiles in the same path.
	sed -i \
		-e '/CFILESSRC.*=/s,american-english,words,' \
		tests/util/grub-fs-tester.in \
		|| die

	if [[ -n ${GRUB_AUTOGEN} ]]; then
		python_setup
		bash autogen.sh || die
		# Flatcar: Force the use of newer gettext infra to
		# avoid build issues with infra version mismatches.
		eautopoint --force
		eautoreconf
	fi
}

grub_do() {
	multibuild_foreach_variant run_in_build_dir "$@"
}

grub_do_once() {
	multibuild_for_best_variant run_in_build_dir "$@"
}

grub_configure() {
	local platform

	case ${MULTIBUILD_VARIANT} in
		efi*) platform=efi ;;
		xen*) platform=xen ;;
		arm64) platform=efi ;;
		guessed) ;;
		*) platform=${MULTIBUILD_VARIANT} ;;
	esac

	case ${MULTIBUILD_VARIANT} in
		*-32)
			if [[ ${CTARGET:-${CHOST}} == x86_64* ]]; then
				local CTARGET=${CTARGET:-i386}
			fi ;;
		*-64)
			if [[ ${CTARGET:-${CHOST}} == i?86* ]]; then
				local CTARGET=${CTARGET:-x86_64}
				local -x TARGET_CFLAGS="-Os -march=x86-64 ${TARGET_CFLAGS}"
				local -x TARGET_CPPFLAGS="-march=x86-64 ${TARGET_CPPFLAGS}"
			fi ;;
		arm64)
			local CTARGET=aarch64-cros-linux-gnu ;;
	esac

	local myeconfargs=(
		--disable-werror
		--program-prefix=
		--libdir="${EPREFIX}"/usr/lib
		--htmldir="${EPREFIX}"/usr/share/doc/${PF}/html
		$(use_enable debug mm-debug)
		$(use_enable device-mapper)
		$(use_enable mount grub-mount)
		$(use_enable nls)
		$(use_enable themes grub-themes)
		$(use_enable truetype grub-mkfont)
		$(use_enable libzfs)
		$(use sdl && use_enable debug grub-emu-sdl)
		${platform:+--with-platform=}${platform}

		# Let configure detect this where supported
		$(usex efiemu '' '--disable-efiemu')
	)

	if use multislot; then
		myeconfargs+=( --program-transform-name="s,grub,grub2," )
	fi

	# Set up font symlinks
	ln -s "${WORKDIR}/${UNIFONT}.pcf" unifont.pcf || die
	if use themes; then
		ln -s "${WORKDIR}/${DEJAVU}/ttf/DejaVuSans.ttf" DejaVuSans.ttf || die
	fi

	local ECONF_SOURCE="${S}"
	econf "${myeconfargs[@]}"
}

src_configure() {
	# Bug 508758.
	replace-flags -O3 -O2

	# We don't want to leak flags onto boot code.
	export HOST_CCASFLAGS=${CCASFLAGS}
	export HOST_CFLAGS=${CFLAGS}
	export HOST_CPPFLAGS=${CPPFLAGS}
	export HOST_LDFLAGS=${LDFLAGS}
	unset CCASFLAGS CFLAGS CPPFLAGS LDFLAGS

	use static && HOST_LDFLAGS+=" -static"

	tc-ld-disable-gold #439082 #466536 #526348
	export TARGET_LDFLAGS="${TARGET_LDFLAGS} ${LDFLAGS}"
	unset LDFLAGS

	tc-export CC NM OBJCOPY RANLIB STRIP
	tc-export BUILD_CC # Bug 485592

	MULTIBUILD_VARIANTS=()
	local p
	for p in "${GRUB_ALL_PLATFORMS[@]}"; do
		use "grub_platforms_${p}" && MULTIBUILD_VARIANTS+=( "${p}" )
	done
	[[ ${#MULTIBUILD_VARIANTS[@]} -eq 0 ]] && MULTIBUILD_VARIANTS=( guessed )
	grub_do grub_configure
}

src_compile() {
	# Sandbox bug 404013.
	use libzfs && addpredict /etc/dfs:/dev/zfs

	grub_do emake
	use doc && grub_do_once emake -C docs html
}

src_test() {
	# The qemu dependency is a bit complex.
	# You will need to adjust QEMU_SOFTMMU_TARGETS to match the cpu/platform.
	grub_do emake check
}

src_install() {
	grub_do emake install DESTDIR="${D}" bashcompletiondir="$(get_bashcompdir)"
	use doc && grub_do_once emake -C docs install-html DESTDIR="${D}"

	einstalldocs

	if use multislot; then
		mv "${ED%/}"/usr/share/info/grub{,2}.info || die
	fi

	insinto /etc/default
	newins "${FILESDIR}"/grub.default-3 grub
}

pkg_postinst() {
	elog "For information on how to configure GRUB2 please refer to the guide:"
	elog "    https://wiki.gentoo.org/wiki/GRUB2_Quick_Start"

	if has_version 'sys-boot/grub:0'; then
		elog "A migration guide for GRUB Legacy users is available:"
		elog "    https://wiki.gentoo.org/wiki/GRUB2_Migration"
	fi

	if [[ -z ${REPLACING_VERSIONS} ]]; then
		elog
		elog "You may consider installing the following optional packages:"
		optfeature "Detect other operating systems (grub-mkconfig)" sys-boot/os-prober
		optfeature "Create rescue media (grub-mkrescue)" dev-libs/libisoburn
		optfeature "Enable RAID device detection" sys-fs/mdadm
	fi
}
