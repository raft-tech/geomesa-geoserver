#! /usr/bin/env bash

dir="$(cd "$(dirname "$0")" || exit; pwd)"

# exit on error, propagate failures through pipe commands, fail on unset variables, don't overwrite files
set -o errexit -o pipefail -o nounset -o noclobber

# pointer to geomesa repo - assumes that the two repos are checked out side-by-side
geomesa_dir="$dir/../../geomesa"
jdk=11
debug=""
geomesa_plugin=""
reset=""

function usage() {
  echo ""
  echo "Usage: $(basename "$0") <options>"
  echo "Configure and run a GeoServer instance with GeoMesa plugins"
  echo ""
  echo "Options:"
  echo "  --install <plugin>        Install the GeoMesa plugin <plugin> into the GeoServer managed by this script"
  echo "  --reset                   Wipe out any existing geoserver managed by this script"
  echo "  --java-version <version>  Set the Java major version used to run GeoServer"
  echo "  --geomesa-home <path>     Set the path to a local clone of https://github.com/locationtech/geomesa to use for installing plugins"
  echo "  --debug                   Enable remote debugging on port 5005"
}

options="debug,geomesa-home:,java-version:,install:,reset"
# arg parsing from https://stackoverflow.com/a/29754866/7809538
# shellcheck disable=SC2251
! parsed_args=$(getopt --options= --longoptions=$options --name "$0" -- "$@")
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
  usage
  exit 2
fi

# this call handles quoting
eval set -- "$parsed_args"
while true; do
  case "$1" in
    --debug)
        debug="-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:5005"
        shift
        ;;
    --reset)
        reset="true"
        shift
        ;;
    --install)
        geomesa_plugin="$2"
        shift 2
        ;;
    --geomesa-home)
        geomesa_dir="$2"
        echo "Using GEOMESA_HOME $geomesa_dir"
        shift 2
        ;;
    --java-version)
        jdk="$2"
        echo "Using Java version $jdk"
        shift 2
        ;;
    --)
        shift;
        break
        ;;
  esac
done

if [[ $# -ne 0 ]]; then
  >&2 echo "ERROR: Invalid argument '$1'"
  usage
  exit 2
fi

download_dir="$dir/docker/download"
install_dir="$dir/docker/install"
data_dir="$dir/docker/geoserver-data"
# tomcat 9 is latest supported by geoserver 2.24
image="tomcat:9.0-jdk$jdk"

mkdir -p "$download_dir"
mkdir -p "$install_dir"

gs_version="$(grep '<geoserver.version>' "$dir/../pom.xml" | head -n1 | sed -E 's|.*<geoserver.version>([0-9.][0-9.]*)</geoserver.version>.*|\1|')"
gs_zip="geoserver-${gs_version}-war.zip"
gs_war="$install_dir/geoserver-${gs_version}"
extensions=("wps")

if ! [[ -d "$gs_war" ]]; then
  reset="true"
fi

if [[ -n "$reset$geomesa_plugin" ]]; then
  # main geoserver war
  if [[ -d "$gs_war" ]]; then
    rm -r "$gs_war"
  fi
  mkdir "$gs_war"
  if ! [[ -f "$download_dir/$gs_zip" ]]; then
    echo "Downloading geoserver-${gs_version}"
    curl -L "https://downloads.sourceforge.net/project/geoserver/GeoServer/${gs_version}/${gs_zip}" \
      -o "$download_dir/$gs_zip"
  fi
  echo "Extracting geoserver-${gs_version} to ${gs_war}"
  unzip -qd "$gs_war" "$download_dir/$gs_zip" geoserver.war
  unzip -qd "$gs_war" "$gs_war/geoserver.war"
  rm "$gs_war/geoserver.war"

  # geoserver extensions
  for ext in "${extensions[@]}"; do
    ext_zip="geoserver-${gs_version}-${ext}-plugin.zip"
    if ! [[ -f "$download_dir/$ext_zip" ]]; then
      echo "Downloading $ext plugin"
      curl -L "https://downloads.sourceforge.net/project/geoserver/GeoServer/${gs_version}/extensions/${ext_zip}" \
        -o "$download_dir/$ext_zip"
    fi
    echo "Extracting $ext plugin"
    unzip -qnd "$gs_war/WEB-INF/lib" "$download_dir/$ext_zip" "*.jar"
  done

  # geomesa data store plugin
  if [[ -n "$geomesa_plugin" ]]; then
    plugin_search_path="$geomesa_dir/geomesa-$geomesa_plugin/geomesa-$geomesa_plugin-gs-plugin/target/"
    plugin="$(find "$plugin_search_path" -name "*-install.tar.gz")"
    if [[ -n "$plugin" ]]; then
      echo "Extracting $(basename "$plugin")"
      tar -xf "$plugin" -C "$gs_war/WEB-INF/lib/"
    else
      >&2 echo "ERROR: no plugin found for $geomesa_plugin"
      >&2 echo "Available plugins:"
      find "$geomesa_dir" -name "geomesa-*-gs-plugin" | grep -v archetypes \
        | xargs -n1 basename | sed 's/geomesa-\(.*\)-gs-plugin/  \1/' >&2
      exit 1
    fi
    tools_search_path="$geomesa_dir/geomesa-$geomesa_plugin/geomesa-$geomesa_plugin-dist/target/"
    tools="$(find "$tools_search_path" -name "*-bin.tar.gz" | head -n1)"
    if [[ -z "$tools" ]]; then
      >&2 echo "ERROR: no CLI tools found for $geomesa_plugin"
      >&2 echo "Available tools:"
      find "$geomesa_dir" -name "geomesa-*-dist" | grep -v archetypes \
        | xargs -n1 basename | sed 's/geomesa-\(.*\)-dist/  \1/' >&2
      exit 1
    else
      tools_dir="$install_dir/$(basename "${tools%-bin.tar.gz}")"
      if [[ -d "$tools_dir" ]]; then
        rm -r "$tools_dir"
      fi
      tar -xf "$tools" -C "$install_dir"
      echo "y" | "$tools_dir/bin/install-dependencies.sh" "$gs_war/WEB-INF/lib/" 2>&1 \
        | grep fetching | sed 's/fetching/Installing/'
    fi

    # geomesa wfs plugin - requires a data store plugin to work
    wfs="$(find "$dir/../geomesa-gs-wfs/target" -name "geomesa-gs-wfs*.jar" | sort -r | head -n1)"
    if [[ -n "$wfs" ]]; then
      echo "Copying $(basename "$wfs")"
      cp "$wfs" "$gs_war/WEB-INF/lib/"
    else
      >&2 echo "ERROR: no WFS plugin found - try building with Maven"
      exit 1
    fi
  fi

  if [[ -n "$reset" ]]; then
    echo "Wiping geoserver-data directory"
    rm -r "$data_dir"
  fi
fi

# this sed command skips TLD jar scanning which improved startup time by ~10-20 seconds
entrypoint="sed -i '/tomcat.util.scan.StandardJarScanFilter.jarsToSkip=/,/.*\.jar$/d' /usr/local/tomcat/conf/catalina.properties"
entrypoint="$entrypoint && echo 'tomcat.util.scan.StandardJarScanFilter.jarsToSkip=\\\n*.jar' >> /usr/local/tomcat/conf/catalina.properties"
# the default container entrypoint is 'catalina.sh run'
entrypoint="$entrypoint && exec catalina.sh run"

echo "Starting geoserver"
# add-opens required by arrow for jdk 11+
docker run --rm \
  --network host \
  -v "$gs_war:/usr/local/tomcat/webapps/geoserver" \
  -v "$data_dir:/tmp/data" \
  -e "CATALINA_OPTS=-DGEOSERVER_DATA_DIR=/tmp/data --add-opens=java.base/java.nio=ALL-UNNAMED $debug" \
  --entrypoint "/bin/sh" \
  "$image" \
  -c "$entrypoint"

## reset permissions on the datadir so that it doesn"t end up owned by tomcat
docker run --rm \
  -v "$data_dir:/tmp/data" \
  --entrypoint bash \
  "$image" \
  -c "chown -R $(id -u):$(id -g) /tmp/data/"
