# *****************************************************************************
#  (c) Copyright IBM Corporation 2024.
# 
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
# ****************************************************************************
# Assisted by watsonx Code Assistant

# Installs the WebSphereOIDCRP administrative application on each cluster within
# a WebSphere traditional cell. When configuring OIDC single-sign-on with ODR 
# front-end, each cluster must have its own WebSphereOIDCRP deployed with a unique
# application name and context root. This task can be ownerous for large deployments; 
# wsadmin scripting can help with automation.
#
# Configuring an OpenID Connect Relying Party
# https://www.ibm.com/docs/en/was-nd/9.0.5?topic=users-configuring-openid-connect-relying-party
#
#   Avoid Trouble:
#   If you intend to use OIDC in multiple clusters load-balanced by IBM HTTP Server with the web 
#   server plug-in, install the application to each cluster with a unique application name and 
#   context root.

import sys
import time
import os

def usage(error=""):
    if error != "":
        error(error)
    info("usage: wsadmin -lang jython -f multiClusterAdminAppDeploy.py --earpath <EAR_fully_qualified_path>")
    info("  Example: /opt/IBM/WebSphere/AppServer/installableApps/WebSphereOIDCRP.ear")
    os._exit() # couldn't get sys.exit(1) to work properly

def info(obj):
  print("INFO [%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime()), str(obj)))

def warning(obj):
  print("WARN [%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime()), str(obj)))

def error(obj):
  print("ERR  [%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime()), str(obj)))

SCRIPT_NAME = "multiClusterAdminAppDeploy.py"
SCRIPT_VERSION = "0.1.20250807"
JYTHON_VERSION = sys.version_info

info(SCRIPT_NAME + " " + SCRIPT_VERSION + " Jython: " + str(JYTHON_VERSION.major) + "." + str(JYTHON_VERSION.minor) + "." + str(JYTHON_VERSION.micro))

l = len(sys.argv)
i = 0
help_flag = False
ear_file = None

while i < l:
  arg = sys.argv[i]
  if arg == "--help" or arg == "--h" or arg == "--usage" or arg == "--?":
    help_flag = True
    break
  elif arg == "--earpath":
    i += 1
    if i < l:
        ear_file = sys.argv[i]
    else:
        error("--earfile requires a file path argument.")
        help_flag = True
  else:
    error("Unknown argument " + arg)
    help_flag = True
  i += 1

if help_flag:
  usage()

default_app_name = 'WebSphereOIDCRP'
ear_file = '/opt/IBM/WebSphere/AppServer/installableApps/WebSphereOIDCRP.ear'
clusters = AdminClusterManagement.listClusters()
for cluster in clusters:
    cluster_name = cluster.split('(')[0]
    app_name = default_app_name + '_' + cluster_name
    print("Installing {} on cluster {} with default context root.".format(app_name, cluster_name))
    AdminApp.install(ear_file, ['-appname', app_name, '-cluster', cluster_name, '-MapWebModToVH', \
        [['OIDC Relying Party callback Servlet', \
        'com.ibm.ws.security.oidc.servlet.war,WEB-INF/web.xml', 'default_host']]])
    try:
        contextRoot = "oidcclient_" + cluster_name
        edit_args = [
            '-CtxRootForWebMod',
            "[{contextRoot}, com.ibm.ws.security.oidc.servlet.war,WEB-INF/web.xml]"
        ]
        AdminApp.edit(app_name, '[ -CtxRootForWebMod [[ "OIDC Relying Party callback Servlet" \
            com.ibm.ws.security.oidc.servlet.war,WEB-INF/web.xml /' + contextRoot + ' ]]]' )
        print("Application {} edited successfully on cluster {}.".format(app_name, cluster_name))        
    except Exception as e:
        print("Failed to edit application {} on cluster {}: {}".format(app_name, cluster_name, e))
    AdminConfig.save()
    AdminNodeManagement.syncActiveNodes()
    AdminApplication.startApplicationOnCluster(app_name, cluster_name)
print("Script execution completed.")

