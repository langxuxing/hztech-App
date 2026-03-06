#!/bin/sh

#
# Copyright © 2015-2021 the original authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

##############################################################################
# Gradle start up script for POSIX (Gradle 8.2)
##############################################################################

# Resolve links: $0 may be a link
app_path=$0
while [ -h "$app_path" ]; do
  ls=$( ls -ld "$app_path" )
  link=${ls#*' -> '}
  case $link in
    /*) app_path=$link ;;
    *) app_path=$APP_HOME$link ;;
  esac
done
APP_BASE_NAME=${0##*/}
APP_HOME=$( cd "${app_path%/*}" && pwd -P ) || exit

CLASSPATH=$APP_HOME/gradle/wrapper/gradle-wrapper.jar

# Java
if [ -n "$JAVA_HOME" ]; then
  JAVACMD=$JAVA_HOME/bin/java
  [ ! -x "$JAVACMD" ] && echo "ERROR: JAVA_HOME is set to an invalid directory: $JAVA_HOME" >&2 && exit 1
else
  JAVACMD=java
  command -v java >/dev/null 2>&1 || { echo "ERROR: JAVA_HOME is not set and no 'java' in PATH" >&2; exit 1; }
fi

DEFAULT_JVM_OPTS="-Dfile.encoding=UTF-8 -Xmx64m -Xms64m"
exec "$JAVACMD" $DEFAULT_JVM_OPTS -classpath "$CLASSPATH" org.gradle.wrapper.GradleWrapperMain "$@"
