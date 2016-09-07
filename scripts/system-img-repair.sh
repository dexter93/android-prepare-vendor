#!/usr/bin/env bash
#
# For latest Android Nexus devices (N5x, N6p, N9, etc.), Google is no longer
# providing vendor archives to be included into AOSP build trees.
# Officially it is claimed that all vendor proprietary blobs have been moved
# to /vendor partition. Unfortunately that is not true since a few vendor
# executables, DSOs and APKs/JARs are present under /system although missing
# from AOSP public tree.
#
# As such custom AOSP builds require to first extract such blobs from /system
# of factory images and manually include them in vendor directory of AOSP tree.
# This process is going anal++ due to the fact that APKs/JARs under /system are
# pre-optimized, requiring to reverse the process (de-optimize them) before
# being capable to copy and include them in AOSP build trees.
#
# This script aims to automate the de-optimization process by creating a copy
# of the input system partition while repairing all optimized bytecode
# packages. Before using this script you'll be required to perform the
# following steps:
#  a) Download matching factory image from Google developers website
#  b) Extract downloaded archives & use simg2img tool to convert the system.
#     img sparse image to raw Linux image
#  c) Mount system raw image to loopback interface and extract all directories
#     while maintaining directory structure
#  d) Execute this script against the root of extracted system directory
#

set -e # fail on unhandled error
set -u # fail on undefined variable
#set -x # debug

readonly TMP_WORK_DIR=$(mktemp -d /tmp/android_img_repair.XXXXXX) || exit 1
declare -a sysTools=("cp" "sed" "java" "zipinfo" "jar" "zip" "wc" "cut")

abort() {
  # If debug keep work dir for bugs investigation
  if [[ "$-" == *x* ]]; then
    echo "[*] Workspace available at '$TMP_WORK_DIR' - delete manually \
          when done"
  else
    rm -rf "$TMP_WORK_DIR"
  fi
  exit "$1"
}

usage() {
cat <<_EOF
  Usage: $(basename "$0") [options]
    OPTIONS:
      -i|--input   : Root path of extracted factory image system partition
      -o|--output  : Path to save input partition with de-optimized odex files
      -m|--method  : Repair methods ('NONE', 'OAT2DEX', 'OATDUMP')
      --oat2dex    : [OPTIONAL] Path to SmaliEx oat2dex.jar (when 'OAT2DEX' method)
      --oatdump    : [OPTIONAL] Path to ART oatdump executable (when 'OATDUMP' method)
      --dexrepair  : [OPTIONAL] Path to dexrepair executable (when 'OATDUMP' method)
      --blobs-list : [OPTIONAL] list with blobs that need to be included in master
                     makefile. When provided only required bytecode is repaired.
    INFO:
      * Input path expected to be system root as extracted from factory system image
      * Download oat2dex.jar from 'https://github.com/testwhat/SmaliEx'
      * Download dexrepair from 'https://github.com/anestisb/dexRepair'
      * When creating vendor makefiles, extra care is needed for APKs signature type
      * '--blobs-list' flag is provided to speed up things in case only specific files are wanted
_EOF
  abort 1
}

command_exists() {
  type "$1" &> /dev/null
}

print_expected_imgs_ver() {
  bootloader=$(grep 'ro.build.expect.bootloader' "$1" | cut -d '=' -f2)
  baseband=$(grep 'ro.build.expect.baseband' "$1" | cut -d '=' -f2)
  echo "[!] Target device expects to have following img versions when using output system img"
  echo " [*] Booatloder:$bootloader"
  echo " [*] Baseband:$baseband"
}

get_build_id() {
  local build_id=$(grep 'ro.build.id=' "$1" | cut -d "=" -f2)
  echo "$build_id"
}

check_java_version() {
  local JAVA_VER=$(java -version 2>&1 | \
                   grep -E "java version|openjdk version" | \
                   awk '{ print $3 }' | tr -d '"' | \
                   awk '{ split($0, data, ".") } END{ print data[2] }')
  if [[ $JAVA_VER -lt 8 ]]; then
    echo "[-] Java version ('$JAVA_VER') is detected, while minimum required version is 8"
    echo "[!] Consider exporting PATH like the following if a system-wide set is not desired"
    echo ' # PATH=/usr/local/java/jdk1.8.0_71/bin:$PATH; ./execute-all.sh <..args..>'
    abort 1
  fi
}

array_contains() {
  local element
  for element in "${@:2}"; do [[ "$element" =~ "$1" ]] && return 0; done
  return 1
}

oat2dex_repair() {
  local -a ABIS

  # Identify supported ABI(s) - extra work for 64bit ABIs
  for type in "arm" "arm64" "x86" "x86_64"
  do
    if [ -f "$INPUT_DIR/framework/$type/boot.art" ]; then
      ABIS=("${ABIS[@]-}" "$type")
    fi
  done

  for abi in ${ABIS[@]}
  do
    echo "[*] Preparing environment for '$abi' ABI"
    workDir="$TMP_WORK_DIR/$abi"
    mkdir -p "$workDir"
    cp "$INPUT_DIR/framework/$abi/boot.oat" "$workDir"
    java -jar "$OAT2DEX_JAR" boot "$workDir/boot.oat" &>/dev/null || {
      echo "[!] Boot classes extraction failed"
      abort 1
    }
  done

  echo "[*] Start processing system partition & de-optimize pre-compiled bytecode"

  while read -r file
  do
    relFile=$(echo "$file" | sed "s#^$INPUT_DIR##")
    relDir=$(dirname "$relFile")
    fileExt="${file##*.}"
    fileName=$(basename "$relFile")

    # Skip special files
    if [[ "$fileExt" == "odex" || "$fileExt" == "oat" || "$fileExt" == "art" ]]; then
      continue
    fi

    # Maintain dir structure
    mkdir -p "$OUTPUT_SYS/$relDir"

    # If not APK/jar file, copy as is
    if [[ "$fileExt" != "apk" && "$fileExt" != "jar" ]]; then
      cp -a "$file" "$OUTPUT_SYS/$relDir/"
      continue
    fi

    # If APKs selection enabled, skip if not in list
    if [[ "$hasAPKSList" = true && "$fileExt" == "apk" && "$relDir" != "/framework" ]]; then
      if ! array_contains "$relFile" "${APKS_LIST[@]}"; then
        continue
      fi
    fi

    # For APK/jar files apply de-optimization
    zipRoot=$(dirname "$file")
    pkgName=$(basename "$file" ".$fileExt")

    # Check if APK/jar bytecode is pre-optimized
    odexFound=0
    if [ -d "$zipRoot/oat" ]; then
      # Check if optimized code available at app's directory
      odexFound=$(find "$zipRoot/oat" -type f -iname "$pkgName*.odex" | \
                  wc -l | tr -d ' ')
    fi
    if [[ $odexFound -eq 0 && "$relFile" == "/framework/"* ]]; then
      # Boot classes have already been de-optimized. Just check against any ABI
      # to verify that is present (not all jars under framework are part of
      # boot.oat)
      odexFound=$(find "$TMP_WORK_DIR/${ABIS[1]}/dex" -type f \
                  -iname "$pkgName*.dex" | wc -l | tr -d ' ')
    fi
    if [ $odexFound -eq 0 ]; then
      # shellcheck disable=SC2015
      zipinfo "$file" classes.dex &>/dev/null && {
        echo "[*] '$file' not pre-optimized with sanity checks passed - copying without changes"
        cp "$file" "$OUTPUT_SYS/$relDir"
      } || {
        echo "[-] '$file' not pre-optimized & without 'classes.dex' - skipping"
      }
    else
      # If pre-compiled, de-optimize to original DEX bytecode
      for abi in ${ABIS[@]}
      do
        curOdex="$zipRoot/oat/$abi/$pkgName.odex"
        if [ -f "$curOdex" ]; then
          # If odex present de-optimize it
          java -jar "$OAT2DEX_JAR" -o "$TMP_WORK_DIR" "$curOdex" \
               "$TMP_WORK_DIR/$abi/dex" &>/dev/null || {
            echo "[!] '$relFile/oat/$abi/$pkgName.odex' de-optimization failed"
            abort 1
          }

          # If DEX not created, oat2dex failed to resolve a dependency and skipped file
          if [ ! -f "$TMP_WORK_DIR/$pkgName.dex" ]; then
            echo "[-] '$relFile' de-optimization failed consider manual inspection - skipping archive"
            continue 2
          fi
        elif [ -f "$TMP_WORK_DIR/$abi/dex/$pkgName.dex" ]; then
          # boot classes bytecode is available from boot.oat extracts - copy
          # them with wildcard so following multi-dex detection logic can pick
          # them up
          cp "$TMP_WORK_DIR/$abi/dex/$pkgName"*.dex "$TMP_WORK_DIR"
        fi
      done

      # If bytecode compiled for more than one ABIs - only the last is kept
      # (shouldn't make any difference)
      if [ ! -f "$TMP_WORK_DIR/$pkgName.dex" ]; then
        echo "[-] Something is wrong in expected dir structure - inspect manually"
        abort 1
      fi

      # Copy APK/jar to workspace for repair
      cp "$file" "$TMP_WORK_DIR"

      # Add dex files back to zip archives (jar or APK) considering possible
      # multi-dex case zipalign is not necessary since AOSP build rules will
      # align them if not already
      if [ -f "$TMP_WORK_DIR/$pkgName-classes2.dex" ]; then
        echo "[*] '$relFile' is multi-dex - adjusting recursive archive adds"
        counter=2
        curMultiDex="$TMP_WORK_DIR/$pkgName-classes$counter.dex"
        while [ -f "$curMultiDex" ]
        do
          mv "$curMultiDex" "$TMP_WORK_DIR/classes$counter.dex"
          jar -uf "$TMP_WORK_DIR/$fileName" -C "$TMP_WORK_DIR" \
               "classes$counter.dex" &>/dev/null || {
            echo "[-] '$fileName' 'classes$counter.dex' append failed"
            abort 1
          }
          rm "$TMP_WORK_DIR/classes$counter.dex"

          counter=$(( counter + 1))
          curMultiDex="$TMP_WORK_DIR/$pkgName-classes$counter.dex"
        done
      fi

      mv "$TMP_WORK_DIR/$pkgName.dex" "$TMP_WORK_DIR/classes.dex"
      jar -uf "$TMP_WORK_DIR/$fileName" -C "$TMP_WORK_DIR" \
           classes.dex &>/dev/null || {
        echo "[-] '$fileName' classes.dex append failed"
        abort 1
      }
      rm "$TMP_WORK_DIR/classes.dex"

      # Remove old signature so that we don't create problems with V2 sign format
      zip -d "$TMP_WORK_DIR/$fileName" META-INF/\* &>/dev/null

      mkdir -p "$OUTPUT_SYS/$relDir"
      cp "$TMP_WORK_DIR/$fileName" "$OUTPUT_SYS/$relDir"
    fi
  done <<< "$(find "$INPUT_DIR" -not -type d)"
}

oatdump_repair() {
  local -a ABIS
  local -a BOOTJARS

  # Identify supported ABI(s) - extra work for 64bit ABIs
  for cpu in "arm" "arm64" "x86" "x86_64"
  do
    if [ -f "$INPUT_DIR/framework/$cpu/boot.art" ]; then
      ABIS=("${ABIS[@]-}" "$cpu")
    fi
  done

  # Cache boot jars so that we can skip them so that we don't have to increase
  # the repair complexity due to them following different naming/dir conventions
  while read -r file
  do
    jarFile="$(basename "$file" | cut -d '-' -f2- | sed 's#.oat#.jar#')"
    BOOTJARS=("${BOOTJARS[@]-}" "$jarFile")
  done <<< "$(find "$INPUT_DIR/framework/${ABIS[1]}" -iname "boot-*.oat")"

  while read -r file
  do
    relFile=$(echo "$file" | sed "s#^$INPUT_DIR##")
    relDir=$(dirname "$relFile")
    fileExt="${file##*.}"
    fileName=$(basename "$relFile")

    odexFound=0
    dexsExported=0

    # Skip special files
    if [[ "$fileExt" == "odex" || "$fileExt" == "oat" || "$fileExt" == "art" ]]; then
      continue
    fi

    # Maintain dir structure
    mkdir -p "$OUTPUT_SYS/$relDir"

    # If not APK/jar file, copy as is
    if [[ "$fileExt" != "apk" && "$fileExt" != "jar" ]]; then
      cp -a "$file" "$OUTPUT_SYS/$relDir/"
      continue
    fi

    # If boot jar skip
    if array_contains "$fileName" "${BOOTJARS[@]}"; then
      continue
    fi

    # If APKs selection enabled, skip if not in list
    if [[ "$hasAPKSList" = true && "$fileExt" == "apk" && "$relDir" != "/framework" ]]; then
      if ! array_contains "$relFile" "${APKS_LIST[@]}"; then
        continue
      fi
    fi

    # For APK/jar files apply repair method without de-optimizing
    zipRoot=$(dirname "$file")
    pkgName=$(basename "$file" ".$fileExt")

    # Check if APK/jar bytecode is pre-optimized
    if [ -d "$zipRoot/oat" ]; then
      # Check if optimized code available at app's directory for all ABIs
      odexFound=$(find "$zipRoot/oat" -type f -iname "$pkgName*.odex" | \
                  wc -l | tr -d ' ')
    fi
    if [ $odexFound -eq 0 ]; then
      # shellcheck disable=SC2015
      zipinfo "$file" classes.dex &>/dev/null && {
        echo "[*] '$file' not pre-optimized with sanity checks passed - copying without changes"
        cp "$file" "$OUTPUT_SYS/$relDir"
      } || {
        echo "[-] '$file' not pre-optimized & without 'classes.dex' - skipping"
      }
    else
      # If pre-compiled, dump bytecode from oat .rodata section
      # If bytecode compiled for more than one ABIs - only the first is kept
      # (shouldn't make any difference)
      for abi in ${ABIS[@]}
      do
        curOdex="$zipRoot/oat/$abi/$pkgName.odex"
        if [ -f "$curOdex" ]; then
          $OATDUMP_BIN --oat-file="$curOdex" \
               --export-dex-to="$TMP_WORK_DIR" &>/dev/null || {
            echo "[!] DEX dump from '$curOdex' failed"
            abort 1
          }

          # If DEX not created, oat2dex failed to resolve a dependency and skipped file
          dexsExported=$(find "$TMP_WORK_DIR" -maxdepth 1 -type f -name "*_export.dex" | wc -l | tr -d ' ')
          if [ $dexsExported -eq 0 ]; then
            echo "[-] '$relFile' de-optimization failed consider manual inspection - skipping archive"
            continue 2
          else
            # Abort inner loop on first match
            continue
          fi
        fi
      done

      # Repair CRC for all dex files & remove un-repaired original dumps
      $DEXREPAIR_BIN -I "$TMP_WORK_DIR" &>/dev/null
      rm -f "$TMP_WORK_DIR/"*_export.dex

      # Copy APK/jar to workspace for repair
      cp "$file" "$TMP_WORK_DIR"

      # Normalize names & add dex files back to zip archives (jar or APK)
      # considering possible multi-dex cases. zipalign is not necessary since
      # AOSP build rules will align them if not already
      if [ $dexsExported -gt 1 ]; then
        # multi-dex file
        echo "[*] '$relFile' is multi-dex - adjusting recursive archive adds"
        counter=2
        curMultiDex="$(find "$TMP_WORK_DIR" -type f -maxdepth 1 "*$counter*_repaired.dex")"
        while [ "$curMultiDex" != "" ]
        do
          mv "$curMultiDex" "$TMP_WORK_DIR/classes$counter.dex"
          jar -uf "$TMP_WORK_DIR/$fileName" -C "$TMP_WORK_DIR" \
               "classes$counter.dex" &>/dev/null || {
            echo "[-] '$fileName' 'classes$counter.dex' append failed"
            abort 1
          }
          rm "$TMP_WORK_DIR/classes$counter.dex"

          counter=$(( counter + 1))
          curMultiDex="$(find "$TMP_WORK_DIR" -type f -maxdepth 1 "*$counter*_repaired.dex")"
        done
      fi

      # All archives have at least one "classes.dex"
      mv "$TMP_WORK_DIR/"*_repaired.dex "$TMP_WORK_DIR/classes.dex"
      jar -uf "$TMP_WORK_DIR/$fileName" -C "$TMP_WORK_DIR" \
         classes.dex &>/dev/null || {
        echo "[-] '$fileName' classes.dex append failed"
        abort 1
      }
      rm "$TMP_WORK_DIR/classes.dex"

      # Remove old signature so that we don't create problems with V2 sign format
      zip -d "$TMP_WORK_DIR/$fileName" META-INF/\* &>/dev/null

      mkdir -p "$OUTPUT_SYS/$relDir"
      mv "$TMP_WORK_DIR/$fileName" "$OUTPUT_SYS/$relDir"
    fi
  done <<< "$(find "$INPUT_DIR" -not -type d)"
}

trap "abort 1" SIGINT SIGTERM

# Check that system tools exist
for i in "${sysTools[@]}"
do
  if ! command_exists "$i"; then
    echo "[-] '$i' command not found"
    abort 1
  fi
done

# Verify Java version >= 8
check_java_version

INPUT_DIR=""
OUTPUT_DIR=""
REPAIR_METHOD=""
BLOBS_LIST_FILE=""

# Paths for external tools provided from args
OAT2DEX_JAR=""
OATDUMP_BIN=""
DEXREPAIR_BIN=""

# Global variables accessible from sub-routines
declare -a APKS_LIST
hasAPKSList=false

while [[ $# -gt 1 ]]
do
  arg="$1"
  case $arg in
    -i|--input)
      INPUT_DIR=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    -o|--output)
      OUTPUT_DIR=$(echo "$2" | sed 's:/*$::')
      shift
      ;;
    -m|--method)
      REPAIR_METHOD="$2"
      shift
      ;;
    --oat2dex)
      OAT2DEX_JAR="$2"
      shift
      ;;
    --oatdump)
      OATDUMP_BIN="$2"
      shift
      ;;
    --dexrepair)
      DEXREPAIR_BIN="$2"
      shift
      ;;
    --blobs-list)
      BLOBS_LIST_FILE="$2"
      shift
      ;;
    *)
      echo "[-] Invalid argument '$1'"
      usage
      ;;
  esac
  shift
done

if [[ "$INPUT_DIR" == "" || ! -d "$INPUT_DIR" ]]; then
  echo "[-] Input directory not found"
  usage
fi
if [[ "$OUTPUT_DIR" == "" || ! -d "$OUTPUT_DIR" ]]; then
  echo "[-] Output directory not found"
  usage
fi
if [[ "$REPAIR_METHOD" != "NONE" && "$REPAIR_METHOD" != "OAT2DEX" && "$REPAIR_METHOD" != "OATDUMP" ]]; then
  echo "[-] Invalid repair method"
  usage
fi
if [[ "$OAT2DEX_JAR" != "" && ! -f "$OAT2DEX_JAR" ]]; then
  echo "[-] oat2dex.jar not found"
  usage
fi
if [[ "$OATDUMP_BIN" != "" && ! -f "$OATDUMP_BIN" ]]; then
  echo "[-] oatdump bin not found"
  usage
fi
if [[ "$DEXREPAIR_BIN" != "" && ! -f "$DEXREPAIR_BIN" ]]; then
  echo "[-] dexrepair bin not found"
  usage
fi
if [[ "$BLOBS_LIST_FILE" != "" && ! -f "$BLOBS_LIST_FILE" ]]; then
  echo "[-] '$BLOBS_LIST_FILE' file not found"
  usage
fi

# Verify input is an Android system partition
if [ ! -f "$INPUT_DIR/build.prop" ]; then
  echo "[-] '$INPUT_DIR' is not a valid system image partition"
  abort 1
fi

# Output directory should be empty to avoid merge races with old extracts
OUTPUT_SYS="$OUTPUT_DIR/system"
if [[ -d "$OUTPUT_SYS" && $(ls -A "$OUTPUT_SYS" | grep -v '^\.') ]]; then
  echo "[!] Output directory should be empty to avoid merge problems with old extracts"
  abort 1
else
  mkdir -p "$OUTPUT_SYS"
fi

# Verify image contains pre-optimized oat files
if [ ! -d "$INPUT_DIR/framework/oat" ]; then
  echo "[!] System partition doesn't contain any pre-optimized files - moving as is"
  mv "$INPUT_DIR" "$OUTPUT_DIR"
  abort 0
fi

# No repairing
if [[ "$REPAIR_METHOD" == "NONE" ]]; then
  echo "[*] No repairing enabled - moving partition as is"
  mv "$INPUT_DIR" "$OUTPUT_DIR"
  abort 0
fi

# Check if blobs list is set so that only selected APKs will be de-optimized for speed
# JARs under /system/framework are always de-optimized for safety
if [[ "$BLOBS_LIST_FILE" != "" ]]; then
  readarray -t APKS_LIST < <(grep -i "system/.*.apk" "$BLOBS_LIST_FILE")
  echo "[*] '${#APKS_LIST[@]}' APKs will be decompiled along with framework jars"
  hasAPKSList=true
else
  echo "[*] All bytecode files under system partition will be de-optimized"
fi

# oat2dex repairing
if [[ "$REPAIR_METHOD" == "OAT2DEX" ]]; then
  if [[ "$OAT2DEX_JAR" == "" ]]; then
    echo "[-] Missing oat2dex.jar tool"
    abort 1
  fi

  echo "[*] Repairing bytecode under /system partition using oat2dex method"
  oat2dex_repair
elif [[ "$REPAIR_METHOD" == "OATDUMP" ]]; then
  if [[ "$OATDUMP_BIN" == "" || "$DEXREPAIR_BIN" == "" ]]; then
    echo "[-] Missing oatdump and/or dexrepair external tool(s)"
    abort 1
  fi

  echo "[*] Repairing bytecode under /system partition using oatdump method"
  oatdump_repair
fi

echo "[*] System partition successfully extracted & repaired at '$OUTPUT_DIR'"
print_expected_imgs_ver "$INPUT_DIR/build.prop"

abort 0
