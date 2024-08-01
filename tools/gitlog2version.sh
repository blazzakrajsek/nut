#!/bin/sh

# Copyright (C) 2016-2024 by Jim Klimov <jimklimov+nut@gmail.com>
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
#
############################################################################
#
# For setup check NUT_VERSION* in script source.
#
# Helper script to determine the project version in a manner similar to
# what `git describe` produces, but with added numbers after the common
# triplet of semantically versioned numbers:   X.Y.Z.T.B(-C-gHASH)
#   * X: MAJOR - incompatible API changes
#   * Y: MINOR - new features and/or API
#   * Z: PATCH - small bug fixes
#   * T: Commits on trunk since previous release tag
#   * B: Commits on branch since nearest ancestor which is on trunk
# The optional suffix (only for commits which are not tags themselves)
# is provided by `git describe`:
#   * C: Commits on branch since previous release tag
#   * H: Git hash (prefixed by "g" character) of the described commit
# Note that historically NUT did not diligently follow the semver triplet,
# primarily because a snapshot of trunk is tested and released, and work
# moves on with the PATCH part (rarely MINOR one) incremented; no actual
# patches are released to some sustaining track of an older release lineage.
# There were large re-designs that got MAJOR up to 2, though.
#
############################################################################
# Checked with bash 3 and 5, dash, ksh, zsh and even busybox sh;
# OpenIndiana, FreeBSD and OpenBSD sh. Not compatible with csh and tcsh.
# See some examples in https://github.com/networkupstools/nut/issues/1949

LANG=C
LC_ALL=C
TZ=UTC
export LANG LC_ALL TZ

if [ x"${abs_top_srcdir}" = x ]; then
    SCRIPT_DIR="`dirname "$0"`"
    SCRIPT_DIR="`cd "${SCRIPT_DIR}" && pwd`"
    abs_top_srcdir="${SCRIPT_DIR}/.."
fi
if [ x"${abs_top_builddir}" = x ]; then
    abs_top_builddir="${abs_top_srcdir}"
fi

############################################################################
# Numeric-only default version, for AC_INIT and similar consumers
# in case we build without a Git workspace (from tarball, etc.)
# By legacy convention, 3-digit "semver" was for NUT releases, and
# a nominal "semver.1" for any development snapshots afterwards.

# The VERSION_DEFAULT files are absent in Git, but should be provided
# in tarballs. It may be re-generated by NUT autogen.sh script forcibly,
# but is otherwise preferred if present and NUT source dir is not a git
# workspace itself (e.g. when we build from release tarballs in
# a git-tracked repository of distro recipes, do not use that
# distro's own versions for NUT).
# Embedded distros that hack a NUT version are not encouraged to, but
# can, use a NUT_VERSION_FORCED variable or a VERSION_FORCED file with
# higher priority than auto-detection attempts. Unfortunately, some
# appliances tag all software the same with their firmware version;
# if this is required, a (NUT_)VERSION_FORCED_SEMVER envvar or file can
# help identify the actual NUT release version triplet used on the box.
# Please use it, it immensely helps with community troubleshooting!
if [ -s "${abs_top_srcdir}/VERSION_FORCED" ] ; then
    . "${abs_top_srcdir}/VERSION_FORCED" || exit
fi
if [ -s "${abs_top_srcdir}/VERSION_FORCED_SEMVER" ] ; then
    . "${abs_top_srcdir}/VERSION_FORCED_SEMVER" || exit
fi
if [ -n "${NUT_VERSION_FORCED-}" ] ; then
    NUT_VERSION_DEFAULT="${NUT_VERSION_FORCED-}"
    NUT_VERSION_PREFER_GIT=false
fi

if [ -z "${NUT_VERSION_DEFAULT-}" -a -s "${abs_top_builddir}/VERSION_DEFAULT" ] ; then
    . "${abs_top_builddir}/VERSION_DEFAULT" || exit
    [ x"${NUT_VERSION_PREFER_GIT-}" = xtrue ] || { [ -e "${abs_top_srcdir}/.git" ] || NUT_VERSION_PREFER_GIT=false ; }
fi

if [ -z "${NUT_VERSION_DEFAULT-}" -a -s "${abs_top_srcdir}/VERSION_DEFAULT" ] ; then
    . "${abs_top_srcdir}/VERSION_DEFAULT" || exit
    [ x"${NUT_VERSION_PREFER_GIT-}" = xtrue ] || { [ -e "${abs_top_srcdir}/.git" ] || NUT_VERSION_PREFER_GIT=false ; }
fi

# Fallback default, to be updated only during release cycle
[ -n "${NUT_VERSION_DEFAULT-}" ] || NUT_VERSION_DEFAULT='2.8.2.1'

# Default website paths, extended for historic sub-sites for a release
[ -n "${NUT_WEBSITE-}" ] || NUT_WEBSITE="https://www.networkupstools.org/"

# Must be "true" or "false" exactly, interpreted as such below:
[ x"${NUT_VERSION_PREFER_GIT-}" = xfalse ] || { [ -e "${abs_top_srcdir}/.git" ] && NUT_VERSION_PREFER_GIT=true || NUT_VERSION_PREFER_GIT=false ; }

getver_git() {
    # NOTE: The chosen trunk branch must be up to date (may be "origin/master"
    # or "upstream/master", etc.) for resulting version discovery to make sense.
    if [ x"${NUT_VERSION_GIT_TRUNK-}" = x ] ; then
        # Find the newest info, it may be in a fetched branch
        # not yet checked out locally (or long not updated)
        for T in master `git branch -a 2>/dev/null | grep -E '^ *remotes/[^ ]*/master$'` origin/master upstream/master ; do
            git log -1 "$T" 2>/dev/null >/dev/null || continue
            if [ x"${NUT_VERSION_GIT_TRUNK-}" = x ] ; then
                NUT_VERSION_GIT_TRUNK="$T"
            else
                # T is strictly same or newer
                # Assume no deviations from the one true path in a master branch
                git merge-base --is-ancestor "${NUT_VERSION_GIT_TRUNK}" "${T}" 2>/dev/null >/dev/null \
                && NUT_VERSION_GIT_TRUNK="$T"
            fi
        done
        if [ x"${NUT_VERSION_GIT_TRUNK-}" = x ] ; then
            echo "$0: FAILED to discover a NUT_VERSION_GIT_TRUNK in this workspace" >&2
            return 1
        fi
    fi

    # By default, only annotated tags are considered
    ALL_TAGS_ARG=""
    if [ x"${NUT_VERSION_GIT_ALL_TAGS-}" = xtrue ] ; then ALL_TAGS_ARG="--tags" ; fi

    # NOTE: "--always" should not be needed in NUT repos normally,
    # but may help other projects who accept such scheme and script:
    # it tells git to return a commit hash if no tag is matched.
    # It may still be needed on CI systems which only fetch the
    # commit they build and no branch names or tags (minimizing the
    # traffic, storage and general potential for creative errors).
    ALWAYS_DESC_ARG=""
    if [ x"${NUT_VERSION_GIT_ALWAYS_DESC-}" = xtrue ] ; then ALWAYS_DESC_ARG="--always" ; fi

    # Praises to old gits and the new, who may --exclude:
    DESC="`git describe $ALL_TAGS_ARG $ALWAYS_DESC_ARG --match 'v[0-9]*.[0-9]*.[0-9]' --exclude '*-signed' --exclude '*rc*' --exclude '*alpha*' --exclude '*beta*' --exclude '*Windows*' --exclude '*IPM*' 2>/dev/null`" \
    && [ -n "${DESC}" ] \
    || DESC="`git describe $ALL_TAGS_ARG $ALWAYS_DESC_ARG | grep -Ev '(rc|-signed|alpha|beta|Windows|IPM)' | grep -E 'v[0-9]*.[0-9]*.[0-9]'`"
    # Old stripper (also for possible refspec parts like "tags/"):
    #   echo "${DESC}" | sed -e 's/^v\([0-9]\)/\1/' -e 's,^.*/,,'
    if [ x"${DESC}" = x ] ; then echo "$0: FAILED to 'git describe' this codebase" >&2 ; return 1 ; fi

    # How much of the known trunk history is in current HEAD?
    # e.g. all of it when we are on that branch or PR made from its tip,
    # some of it if looking at a historic snapshot, or nothing if looking
    # at the tagged commit (it is the merge base for itself and any of
    # its descendants):
    BASE="`git merge-base HEAD "${NUT_VERSION_GIT_TRUNK}"`" || BASE=""
    if [ x"${BASE}" = x ] ; then echo "$0: FAILED to get a git merge-base of this codebase vs. '${NUT_VERSION_GIT_TRUNK}'" >&2 ; DESC=""; return  1; fi

    # Nearest (annotated by default) tag preceding the HEAD in history:
    TAG="`echo "${DESC}" | sed 's/-[0-9][0-9]*-g[0-9a-fA-F][0-9a-fA-F]*$//'`"

    # Commit count since the tag and hash of the HEAD commit;
    # empty e.g. when HEAD is the tagged commit:
    SUFFIX="`echo "${DESC}" | sed 's/^.*\(-[0-9][0-9]*-g[0-9a-fA-F][0-9a-fA-F]*\)$/\1/'`" && [ x"${SUFFIX}" != x"${TAG}" ] || SUFFIX=""

    # 5-digit version, note we strip leading "v" from the expected TAG value
    VER5="${TAG#v}.`git log --oneline "${TAG}..${BASE}" | wc -l | tr -d ' '`.`git log --oneline "${NUT_VERSION_GIT_TRUNK}..HEAD" | wc -l | tr -d ' '`"
    DESC5="${VER5}${SUFFIX}"

    # Strip up to two trailing zeroes for trunk snapshots and releases
    VER50="`echo "${VER5}" | sed -e 's/\.0$//' -e 's/\.0$//'`"
    DESC50="${VER50}${SUFFIX}"

    # Leave exactly 3 components
    if [ -n "${NUT_VERSION_FORCED_SEMVER-}" ] ; then
        SEMVER="${NUT_VERSION_FORCED_SEMVER-}"
    else
        SEMVER="`echo "${VER5}" | sed -e 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\..*$/\1/'`"
    fi
    # FIXME? Add ".0" up to 3 components?
}

getver_default() {
    NUT_VERSION_DEFAULT_DOTS="`echo "${NUT_VERSION_DEFAULT}" | sed 's/[^.]*//g' | tr -d '\n' | wc -c`"

    # Ensure at least 4 dots (5 presumed-numeric components)
    NUT_VERSION_DEFAULT5_DOTS="${NUT_VERSION_DEFAULT_DOTS}"
    NUT_VERSION_DEFAULT5="${NUT_VERSION_DEFAULT}"
    while [ "${NUT_VERSION_DEFAULT5_DOTS}" -lt 4 ] ; do
        NUT_VERSION_DEFAULT5="${NUT_VERSION_DEFAULT5}.0"
        NUT_VERSION_DEFAULT5_DOTS="`expr $NUT_VERSION_DEFAULT5_DOTS + 1`"
    done

    # Truncate/extend to exactly 2 dots (3 presumed-numeric components)
    NUT_VERSION_DEFAULT3_DOTS="${NUT_VERSION_DEFAULT_DOTS}"
    NUT_VERSION_DEFAULT3="${NUT_VERSION_DEFAULT}"
    while [ "${NUT_VERSION_DEFAULT3_DOTS}" -lt 2 ] ; do
        NUT_VERSION_DEFAULT3="${NUT_VERSION_DEFAULT3}.0"
        NUT_VERSION_DEFAULT3_DOTS="`expr $NUT_VERSION_DEFAULT3_DOTS + 1`"
    done
    while [ "${NUT_VERSION_DEFAULT3_DOTS}" -gt 2 ] ; do
        NUT_VERSION_DEFAULT3="`echo "${NUT_VERSION_DEFAULT3}" | sed 's,\.[0-9][0-9]*$,,'`"
        NUT_VERSION_DEFAULT3_DOTS="`expr $NUT_VERSION_DEFAULT3_DOTS - 1`"
    done

    DESC5="${NUT_VERSION_DEFAULT5}"
    DESC50="${NUT_VERSION_DEFAULT}"
    VER5="${NUT_VERSION_DEFAULT5}"
    VER50="${NUT_VERSION_DEFAULT}"
    SUFFIX=""
    BASE=""
    if [ -n "${NUT_VERSION_FORCED_SEMVER-}" ] ; then
        SEMVER="${NUT_VERSION_FORCED_SEMVER-}"
    else
        SEMVER="${NUT_VERSION_DEFAULT3}"
    fi
    TAG="v${NUT_VERSION_DEFAULT3}"
}

report_debug() {
    # Debug
    echo "TRUNK='${NUT_VERSION_GIT_TRUNK-}'; BASE='${BASE}'; DESC='${DESC}' => TAG='${TAG}' + SUFFIX='${SUFFIX}' => VER5='${VER5}' => VER50='${VER50}' => DESC50='${DESC50}'" >&2
}

report_output() {
    case "${NUT_VERSION_QUERY-}" in
        "DESC5")	echo "${DESC5}" ;;
        "DESC50")	echo "${DESC50}" ;;
        "VER5") 	echo "${VER5}" ;;
        "VER50")	echo "${VER50}" ;;
        "SEMVER")	echo "${SEMVER}" ;;
        "IS_RELEASE")	[ x"${SEMVER}" = x"${VER50}" ] && echo true || echo false ;;
        "TAG")  	echo "${TAG}" ;;
        "SUFFIX")	echo "${SUFFIX}" ;;
        "BASE") 	echo "${BASE}" ;;
        "URL")
            # Clarify the project website URL - particularly historically
            # frozen snapshots made for releases
            if [ x"${SEMVER}" = x"${VER50}" ] ; then
                echo "${NUT_WEBSITE}historic/v${SEMVER}/index.html"
            else
                echo "${NUT_WEBSITE}"
            fi
            ;;
        "UPDATE_FILE")
            if [ x"${abs_top_builddir}" != x"${abs_top_srcdir}" ] \
            && [ -s "${abs_top_srcdir}/VERSION_DEFAULT" ] \
            && [ ! -s "${abs_top_builddir}/VERSION_DEFAULT" ] \
            ; then
                cp -f "${abs_top_srcdir}/VERSION_DEFAULT" "${abs_top_builddir}/VERSION_DEFAULT" || exit
            fi

            echo "NUT_VERSION_DEFAULT='${DESC50}'" > "${abs_top_builddir}/VERSION_DEFAULT.tmp" || exit
            if cmp "${abs_top_builddir}/VERSION_DEFAULT.tmp" "${abs_top_builddir}/VERSION_DEFAULT" >/dev/null 2>/dev/null ; then
                rm -f "${abs_top_builddir}/VERSION_DEFAULT.tmp"
            else
                mv -f "${abs_top_builddir}/VERSION_DEFAULT.tmp" "${abs_top_builddir}/VERSION_DEFAULT" || exit
            fi
            cat "${abs_top_builddir}/VERSION_DEFAULT"
            ;;
        *)		echo "${DESC50}" ;;
    esac
}

DESC=""
if $NUT_VERSION_PREFER_GIT ; then
    if (command -v git && git rev-parse --show-toplevel) >/dev/null 2>/dev/null ; then
        getver_git || { echo "$0: Fall back to pre-set default version information" >&2 ; DESC=""; }
    fi
fi

if [ x"$DESC" = x ]; then
    getver_default
fi

report_debug
report_output

# Set exit code based on availability of default version info data point
# Not empty means good
# TOTHINK: consider the stdout of report_output() instead?
[ x"${DESC50}" != x ]
