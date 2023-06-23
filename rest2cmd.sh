#!/bin/bash
#===========================================================================================
#
#       ARCHIVO:  rest2cmd.sh
# 
#       RESUMEN:  Libreria de funciones que convierten las REST APIs de oVirt 4.4 a comandos
#   DESCRIPCION:  Se traducen las llamadas a REST APIs de oVirt 4.4 a comandos similares a
#   		  los utilizados en las anteriores versiones de oVirt 3.x, donde se tenian
#   		  comandos simples. Este es un trabajo en proceso para intentar mantener la
#   		  compatibilidad con los scripts desarrollados para las versiones anteriores
#   		  de la API. Son bienvenidas cualquier mejora o cambios!!.
#         AUTOR:  Oxiel Enrique Contreras Vargas
#       EMPRESA:  Quantum SRL
#      LICENCIA:  GPLv3.0 - https://www.gnu.org/licenses/gpl-3.0.html
#       VERSION:  0.0.1
#        CREADO:  15/05/23 09:30:45 BOT
#      REVISION:  Oxiel Contreras
#
#	Have a lot of fun ;)
#===========================================================================================
# Variables de Libreria
ORVT_SERVER='olvm.example.com'
ORVT_USERNAME='admin@internal'
ORVT_USERPASS='ABCDEFGHI'
ORVT_URL="https://${ORVT_SERVER}/ovirt-engine/api/"
ORVT_CA="https://${ORVT_SERVER}/ovirt-engine/services/pki-resource?resource=ca-certificate&format=X509-PEM-CA"
CA_FILE='/dev/shm/ca.crt'
REQUISITOS="curl base64 xmllint getopt mktemp"
declare -g {USERCODED,HTTP_AUTH,HTTP_STATUS_PROTO,HTTP_STATUS_CODE,HTTP_STATUS_INFO,HEAD_FILE}=""
# Color variables
C_RED='\e[1;31m'
C_GREEN='\e[1;32m'
C_YELLOW='\e[1;33m'
C_BLUE='\e[1;34m'
C_MAGENTA='\e[1;35m'
C_CYAN='\e[1;36m'
C_CLEAN='\e[0m'
C_BOLD='\e[1m'
##### Fin de variables

leave() {
  echo -e "\nFinalizando conexión...\n"
  rm -f ${CA_FILE} &>/dev/null
  rm -f ${HEAD_FILE} &>/dev/null
}

message(){
  local err_type=${1:-u}
  local message="${2:-Sin mensaje}"
  local err_msg=""

  case ${err_type} in
    e) err_msg="${C_RED}[ERROR]${C_CLEAN} " ;;
    w) err_msg="${C_YELLOW}[WARNING]${C_CLEAN} " ;;
    o) err_msg="${C_GREEN}[OK]${C_CLEAN} " ;;
    *) err_msg="${C_CYAN}[UNKNOWN]${C_CLEAN} " ;;
  esac
  echo -e "\n\n${err_msg}${C_BOLD}${message}${C_CLEAN}\n\n"
}

print_headers() {
  cat "${HEAD_FILE}"
  IFS=" " read -r HTTP_STATUS_PROTO HTTP_STATUS_CODE HTTP_STATUS_INFO <<< "$(grep HTTP ${HEAD_FILE})"
  echo -e "\n${C_MAGENTA}Protocolo: ${C_CLEAN}${C_BOLD}${HTTP_STATUS_PROTO}${C_CLEAN}"
  echo -e "${C_MAGENTA}Código   : ${C_CLEAN}${C_BOLD}${HTTP_STATUS_CODE}${C_CLEAN}"
  echo -e "${C_MAGENTA}Info     : ${C_CLEAN}${C_BOLD}${HTTP_STATUS_INFO}${C_CLEAN}\n"
}

prereqs(){
  for i in ${REQUISITOS}; do
    type -p ${i} &>/dev/null
    [ $? -ne 0 ] && message e "No existe en el PATH el utilitario: ${i}" && exit 1
  done
  trap leave EXIT
  HEAD_FILE=$(mktemp -p /dev/shm)   # Archivo para salvar los headers
}

get_CA() {
  curl -sk --output ${CA_FILE} ${ORVT_CA}

  [ $? -ne 0 ] && message e "No se puede obtener el certificado CA, por favor revise el acceso al servidor: ${ORVT_CA}" && exit 1
  grep -q Error ${CA_FILE} && message e "Certificado CA invalido, por favor revise la URL del certificado." && leave && exit 1
}

xquery() {
  xmllint --xpath "${1}" -
}

call_API() {
  local HTTP_METHOD="${1}"
  local ORVT_PATH="${2}"
  local HTTP_BODY="${3:-}"
  local response=""

  response=$( curl -is \
    --cacert "${CA_FILE}" \
    --header 'Version: 4' \
    --header 'Accept: application/xml' \
    --header 'Content-Type: application/xml' \
    --header "${HTTP_AUTH}" \
    --request ${HTTP_METHOD} \
    --data "${HTTP_BODY}" \
    "${ORVT_URL}${ORVT_PATH}" | sed -e 's/\r//g' )

  echo "${response}" | sed '/^$/q' | grep -v '^$' > ${HEAD_FILE}
  echo "${response}" | sed '1,/^$/d'
}

#Method name    HTTP method
#---------------------------
# add           POST
# get           GET
# list          GET
# update        PUT
# remove        DELETE

get_Creds() {
  USERCODED=$(echo -n "${ORVT_USERNAME}:${ORVT_USERPASS}" | base64)
  HTTP_AUTH="Authorization: Basic ${USERCODED}"

  local result=$(call_API "GET" "")
  echo ${result} | grep -q "access_denied" 1>/dev/null && message e "Clave equivocada, por favor intente de nuevo." && leave && exit 1
}

get() {
  local objeto="${1}"
  local nombre="${2}"
  local resultado=""

  case ${objeto} in
    role) # role no tiene search
      resultado=$(call_API GET "${objeto}s" | xquery "string(//${objeto}[name='${nombre}']/@id)")
      ;;
    nic) # nic debe bucar en la VM primero y buscamos siempre la nic1
      resultado=$(call_API GET "vms/${nombre}/${objeto}s?search=name%3Dnic1" | xquery "string(//${objeto}[1]/@id)")
      ;;
    *) # objetos que cumplen: tag
      resultado=$(call_API GET "${objeto}s?search=name%3D${nombre}" | xquery "string(//${objeto}/@id)")
      ;;
  esac
  echo "${resultado}"
}

list() {
  local objeto="${1}"
  local nombre="${2}"
  local {ruta,consulta,resultado}=""

  case ${objeto} in
    vms|clusters|hosts|tags|disks) # list [vms|clusters|hosts|tags]
      ruta="${objeto}"
      consulta="//${objeto::-1}/@id | //${objeto::-1}/name/text()"
      ;;
    datacenters) # list datacenters
      ruta="${objeto}"
      consulta="//data_center/@id | //data_center/name/text()"
      ;;
    nics) # list nics VMID
      [[ -z ${nombre} ]] && message e "Necesito el ID de la VM que contiene las ${objeto}" && exit 1
      ruta="vms/${nombre}/${objeto}"
      consulta="//${objeto::-1}/@id | //${objeto::-1}/name/text()"
      ;;
    diskattachments) # list diskattachments VMID
      [[ -z ${nombre} ]] && message e "Necesito el ID de la VM que contiene los ${objeto}" && exit 1
      ruta="vms/${nombre}/${objeto}"
      consulta="//disk_attachment/@id | //disk_attachment/disk/@href"
      echo "$ruta --- $consulta"
      ;;
    permissions) # list permissions
      ruta="${objeto}"
      consulta="//${objeto::-1}/@id | //${objeto::-1}/role/@href"
      ;;
    *) message w "No soportamos el listado de ese objeto."
      exit 1  
      ;;
  esac
  resultado=$(call_API GET "${ruta}" | xquery "${consulta}" | sed -e 's/ id="//g' -e 's/"//g' -e '$!N;s/\n/ /')
  echo "${resultado}"
}

action() {
  local objeto="${1}"
  local objid="${2}"
  local accion="${3}"
  local argv=("$@")
  local body="<action/>"
  local resultado=""
  case ${objeto} in
    vm)
      case ${accion} in
        start)
	  if [[ $# -gt 3 ]]; then # Si llegan los parametros --async y --use_sysprep
	    body=""
	    for (( i=3; i<"$#"; i++ )); do
   	      case ${argv[i]} in
	        --use_sysprep|--async) body="${body}<${argv[i]:2}>true</${argv[i]:2}>"
	          ;;
	        *) message w "El comando 'start vm' no soporta la opción: ${argv[i]}"
	          ;;
	      esac
	    done
	    [[ -z ${body} ]] && body="<action/>" || body="<action>${body}</action>"
	  fi
	  resultado=$(call_API POST "${objeto}s/${objid}/${accion}" "${body}" | xquery "string(//status)")
          ;;
        stop|reboot|shutdown|suspend)
	  resultado=$(call_API POST "${objeto}s/${objid}/${accion}" "${body}" | xquery "string(//status)")
          ;;
        *) message u "No existe la acción ${accion}"
          ;;
      esac
      ;;
    *) message u "No manejamos el objeto ${objeto}"
      ;;
  esac
  echo "${resultado}" # Devuelve complete
}

add() {
  local objeto="${1}"
  declare {usage,resultado,body}=""
  shift
  case ${objeto} in
    vm)
      usage='add vm --name NombreVM --template-name NombreTemplate --cluster-name NombreCluster'
      opciones=$(getopt -n 'add vm' -o '' --long name:,template-name:,cluster-name: -- "$@")
      [ "$?" != "0" ] && message e "Parámetros erroneos, el uso es: ${usage}"
      eval set -- "$opciones"
      while [ : ]; do
	case "$1" in
	  --name) body="${body}<name>${2}</name>"; shift 2 ;;
	  --template-name) body="${body}<template><name>${2}</name></template>"; shift 2 ;;
	  --cluster-name) body="${body}<cluster><name>${2}</name></cluster>"; shift 2 ;;
	  --) shift; break ;;
	  *) message e "Opción no esperada: $1 - esto no debería suceder."
	     echo "El uso es: ${usage}" ;;
	esac
      done
      [[ -z ${body} ]] && body="<action/>" || body="<vm>${body}</vm>"
      resultado=$(call_API POST "${objeto}s" "${body}" | xquery "string(/${objeto}/@id)") # Devuelve VMID
      ;;
    user)
      local {username,authzname}=""
      usage='add user --user-name NombreUser --authz-name NombreAuthz'
      opciones=$(getopt -n 'add user' -o '' --long user-name:,authz-name: -- "$@")
      [ "$?" != "0" ] && message e "Parámetros erroneos, el uso es: ${usage}"
      eval set -- "$opciones"
      while [ : ]; do
	case "$1" in
	  --user-name) username="${2}"; shift 2 ;;
	  --authz-name) authzname="${2}"; body="${body}<domain><name>${2}</name></domain>"; shift 2 ;;
	  --) shift; break ;;
	  *) message e "Opción no esperada: $1 - esto no debería suceder."
	     echo "El uso es: ${usage}" ;;
	esac
	body="<user_name>${username}@${authzname}</user_name>${body}"
	[[ "${username}" =~ .+@.+ ]] && body="<principal>${username}</principal>${body}"
      done
      [[ -z ${body} ]] && body="<action/>" || body="<${objeto}>${body}</${objeto}>"
      resultado=$(call_API POST "${objeto}s" "${body}" | xquery "string(/${objeto}/@id)") # Devuelve UserID
      ;;
    tag)
      usage='add tag --name NombreEtiqueta'
      opciones=$(getopt -n 'add tag' -o '' --long name: -- "$@")
      [ "$?" != "0" ] && message e "Parámetros erroneos, el uso es: ${usage}"
      eval set -- "$opciones"
      while [ : ]; do
	case "$1" in
	  --name) body="${body}<name>${2}</name>"; shift 2 ;;
	  --) shift; break ;;
	  *) message e "Opción no esperada: $1 - esto no debería suceder."
	     echo "El uso es: ${usage}" ;;
	esac
      done
      [[ -z ${body} ]] && body="<action/>" || body="<tag>${body}</tag>"
      resultado=$(call_API POST "${objeto}s" "${body}" | xquery "string(/${objeto}/@id)") # Devuelve TagID
      ;;
    permission)
      usage='add permission --parent-vm-id VMID --role-name RolNombre --user-id UserID'
      opciones=$(getopt -n 'add vm' -o '' --long parent-vm-id:,role-name:,user-id: -- "$@")
      [ "$?" != "0" ] && message e "Parámetros erroneos, el uso es: ${usage}"
      eval set -- "$opciones"
      while [ : ]; do
	case "$1" in
	  --parent-vm-id) vmid=${2}; shift 2 ;;
	  --role-name) body="${body}<role><name>${2}</name></role>"; shift 2 ;;
	  --user-id) body="${body}<user id=\"${2}\"/>"; shift 2 ;;
	  --) shift; break ;;
	  *) message e "Opción no esperada: $1 - esto no debería suceder."
	     echo "El uso es: ${usage}" ;;
	esac
      done
      [[ -z ${body} ]] && body="<action/>" || body="<permission>${body}</permission>"
      resultado=$(call_API POST "vms/${vmid}/${objeto}s" "${body}" | xquery "string(/${objeto}/@id)") # Devuelve VMID
      ;;
    *) message u "No manejamos el objeto ${objeto}"
      ;;
  esac
  echo "${resultado}"
}

remove() {
  local objeto="${1}"
  local objid="${2}"
  local resultado=""
  case ${objeto} in
    vm)
      resultado=$(call_API DELETE "${objeto}s/${objid}" "<action><force>true</force></action>" | xquery "string(//status)")
      ;;
    permission)
      usage='remove permission --parent-vm-id VMID --permission-id PermissionID'
      opciones=$(getopt -n 'add vm' -o '' --long parent-vm-id:,permission-id: -- "$@")
      [ "$?" != "0" ] && message e "Parámetros erroneos, el uso es: ${usage}"
      eval set -- "$opciones"
      while [ : ]; do
	case "$1" in
	  --parent-vm-id) vmid=${2}; shift 2 ;;
	  --permission-id) permissionid=${2}; shift 2 ;;
	  --) shift; break ;;
	  *) message e "Opción no esperada: $1 - esto no debería suceder."
	     echo "El uso es: ${usage}" ;;
	esac
      done
      body="<async>true</async>"
      resultado=$(call_API DELETE "vms/${vmid}/${objeto}s/${permissionid}" "${body}" | xquery "string(//status)")
      ;;
    user)
      resultado=$(call_API DELETE "${objeto}s/${objid}" "<async>true</async>" | xquery "string(//status)")
      ;;
    *) message u "No podemos remover el objeto ${objeto}"
      ;;
  esac
  echo "${resultado}" # Devuelve complete
}

update() {
  local objeto="${1}"
  declare {operacion,suboper,subobj,subparam,optargs,usage,resultado,body,http_method,http_ruta,consulta}=""
  shift
  case ${objeto} in
    vm)
      # Paso 0
      # Recorre todos los parametros en busca de las operaciones que soportamos
      # luego extrae las cadenas para armar los parametros abajo
      # ejecuta solo la primera operacion encontrada, ignora las demas
      local argv=("$@")
      for (( i=0; i<"$#"; i++ )); do
	case ${argv[i]} in
	  --add-tag)  subparam='name'; break 2 ;;
	  --remove-tag) subparam='id'; break 2 ;;
	esac
      done
      operacion=${argv[i]}                           # --add-tag
      suboper=$(echo ${operacion%-*} | sed 's/-//g') # add
      subobj=${operacion##*-}                        # tag

      # Paso 1
      # Activa el control de los parametros
      usage="update vm --vm-id VMID ${operacion} --${subobj}-${subparam} ${subobj^}${subparam^}"
      optargs="vm-id:,${operacion:2},${subobj}-${subparam}:"
      opciones=$(getopt -n 'update vm' -o '' --long "${optargs}" -- "$@")
      [ "$?" != "0" ] && message e "Parámetros erroneos, el uso es: ${usage}"
      eval set -- "$opciones"
      
      # POST '<tag><name>LaTuca</name></tag>' /vms/df1e54ec-8bca-4497-8aaa-25fdd9bb9218/tags
      # Paso 2
      # Procesa los parametros segun la operacion que se va realizar
      case ${operacion} in
	--add-tag) # "update vm --vm-id VMID --add-tag --tag-name TagName"
	  while [ : ]; do
	    case "$1" in
	      --vm-id) local vmid=${2}; shift 2 ;;
	      --add-tag) shift  ;;
	      --tag-name) body="${body}<${subparam}>${2}</${subparam}>"; shift 2 ;;
	      --) shift; break ;;
	      *) message e "Opción no esperada: $1 - esto no debería suceder."
		 echo "El uso es: ${usage}" ;;
	    esac
	  done
	  http_method='POST'
	  http_ruta="vms/${vmid}/${subobj}s"
	  consulta="string(//${subobj}/@id)" # Devuelve el id del Tag
	;;
	--remove-tag) # "update vm --vm-id VMID --remove-tag --tag-id TagID"
	  while [ : ]; do
	    case "$1" in
	      --vm-id) local vmid=${2}; shift 2 ;;
	      --remove-tag) body="true"; shift  ;;
	      --tag-id) local tagid="${2}"; shift 2 ;;
	      --) shift; break ;;
	      *) message e "Opción no esperada: $1 - esto no debería suceder."
		 echo "El uso es: ${usage}" ;;
	    esac
	  done
	  http_method='DELETE'
	  http_ruta="vms/${vmid}/${subobj}s/${tagid}"
	  consulta="string(//status)" # Devuelve el status de la tarea: complete
	  subobj="async" # Cambiamos x q eso corresponde con el DELETE para este metodo
	  ;;
      esac

      # Paso 3
      # Realiza la llamada y obtiene el resultado
      [[ -z ${body} ]] && body="<action/>" || body="<${subobj}>${body}</${subobj}>"
      resultado=$(call_API ${http_method} "${http_ruta}" "${body}" | xquery "${consulta}")
      ;;
    nic)
      usage='update nic --nic-id VMNicID --parent-vm-id VMID --mac-address MacAddress'
      opciones=$(getopt -n 'update nic' -o '' --long nic-id:,parent-vm-id:,mac-address: -- "$@")
      [ "$?" != "0" ] && message e "Parámetros erroneos, el uso es: ${usage}"
      eval set -- "$opciones"
      while [ : ]; do
	case "$1" in
	  --nic-id) local nicid=${2}; shift 2 ;;
	  --parent-vm-id) local vmid=${2}; shift 2 ;;
	  --mac-address) body="${body}<mac><address>${2}</address></mac>"; shift 2 ;;
	  --) shift; break ;;
	  *) message e "Opción no esperada: $1 - esto no debería suceder."
	     echo "El uso es: ${usage}" ;;
	esac
      done
      [[ -z ${body} ]] && body="<action/>" || body="<nic>${body}</nic>"
      resultado=$(call_API PUT "vms/${vmid}/${objeto}s/${nicid}" "${body}" | xquery "string(//address)") # Devuelve la MAC actualizada
      ;;
    *) message u "No actualizamos el objeto ${objeto}"
      ;;
  esac
  echo "${resultado}"
}

## Main
prereqs
get_CA
get_Creds
