#!/bin/bash
# USAGE
# ./alerts-check.sh <optional product-name>
# ^C to break
# Generates two files one for firing and one for pending alerts
#
# PREREQUISITES
# - jq
# - oc (logged in at the cmd line in order to get the bearer token)
# VARIABLES

# wait for RHMI CR to appear and have namespace prefix populated
until oc get RHMIs --all-namespaces -o jsonpath='{.items[0].spec.namespacePrefix}' &> /dev/null
do
    echo "Waiting for RHMI CR with namespace prefix set to appear on cluster. Next check to be in 1 minute."
    sleep 60
done

ROUTE="http://localhost:9090/api/v1/alerts"
NAMESPACE_PREFIX="${NAMESPACE_PREFIX:-$(oc get RHMIs --all-namespaces -o jsonpath='{.items[0].spec.namespacePrefix}')}"
TOKEN=$(oc whoami --show-token)
# wait for monitoring route to appear and have host populated
# wait for rhoam install to be complete
until oc exec -n ${NAMESPACE_PREFIX}operator-observability prometheus-rhoam-0 -- wget -qO- --header='Accept: application/json' --header="Authorization: Bearer $TOKEN" --no-check-certificate $ROUTE &> /dev/null && [[ $(oc get rhmi rhoam -n ${NAMESPACE_PREFIX}operator -o json | jq -r '.status.stage') == "complete" ]]
do
    echo "Waiting for ${NAMESPACE_PREFIX}operator-observability pods to be available and RHOAM installation to be complete. Next check in 1 minute."
    sleep 60
done

OPENSHIFT_MONITORING=$(oc exec -n openshift-monitoring prometheus-k8s-0 -- curl $ROUTE -s -H "Authorization: Bearer $TOKEN")
RHOAM_MONITORING=$(oc exec -n ${NAMESPACE_PREFIX}operator-observability prometheus-rhoam-0 -- wget -qO- --header='Accept: application/json' --header="Authorization: Bearer $TOKEN" --no-check-certificate $ROUTE)
# Define an array of monitoring data sources
declare -A monitoring_sources=(
  ["rhoam"]=$RHOAM_MONITORING
  ["openshift"]=$OPENSHIFT_MONITORING
)

# Define an array of products to report on
declare -a products=("3scale" "user-sso" "rhsso" "marin3r")

# Define an array of alert states to report on
declare -a alert_states=("pending" "firing")

# remove tmp files on ctrl-c
trap 'find . -name "tmp-*" -delete; for source_name in "${!monitoring_sources[@]}"; do for alert_state in "${alert_states[@]}"; do if [[ -f "tmp-${source_name}-alert-${alert_state}-during-perf-testing-report.csv" ]]; then rm "tmp-${source_name}-alert-${alert_state}-during-perf-testing-report.csv"; fi; done; done' EXIT

# function to check if there are no alerts firing bar deadmansnitch
function CHECK_NO_ALERTS() {
  # Extract firing alerts from OpenShift monitoring
  openshift_alerts=$(echo "$OPENSHIFT_MONITORING" | jq -r '.data.alerts[] | select(.state == "firing") | [.labels.alertname, .state, .activeAt, .labels.severity] | @csv')

  # Extract firing alerts from RHOAM monitoring
  rhoam_alerts=$(echo "$RHOAM_MONITORING" | jq -r '.data.alerts[] | select(.state == "firing") | [.labels.alertname, .state, .activeAt, .labels.severity] | @csv')

  # Extract pending alerts from OpenShift monitoring
  openshift_alerts_pending=$(echo "$OPENSHIFT_MONITORING" | jq -r '.data.alerts[] | select(.state == "pending") | [.labels.alertname, .state, .activeAt, .labels.severity] | @csv')

  # Extract pending alerts from RHOAM monitoring
  rhoam_alerts_pending=$(echo "$RHOAM_MONITORING" | jq -r '.data.alerts[] | select(.state == "pending") | [.labels.alertname, .state, .activeAt, .labels.severity] | @csv')

  # Combine and sort the alerts
  all_alerts=$(echo -e "${openshift_alerts}\n${rhoam_alerts}" | sort)

  all_alerts_pending=$(echo -e "${openshift_alerts_pending}\n${rhoam_alerts_pending}" | sort)

  # Check if there are no firing alerts
  if [[ $(echo "$all_alerts" | wc -l | xargs) == 1 ]]; then
    echo Only alert firing is DeadMansSwitch
    date
    sleep 5
  elif [[ $(echo "$rhoam_alerts" | wc -l | xargs) == 1 ]] && [[ $(echo "$openshift_alerts" | wc -l | xargs) != 1 ]]; then
    echo "============================================================================"
    date
    echo "Only alert firing is DeadMansSwitch for ${NAMESPACE_PREFIX}operator-observability"
    echo "$rhoam_alerts"
    echo "----------------------------------------------------------------------------"
    echo "Following alerts are firing for openshift-monitoring:"
    echo "$openshift_alerts"
    echo "============================================================================"
    echo "Following alerts are pending for openshift-monitoring:"
    echo "$openshift_alerts_pending"
    echo "============================================================================"
  elif [[ $(echo "$rhoam_alerts" | wc -l | xargs) != 1 ]] && [[ $(echo "$openshift_alerts" | wc -l | xargs) == 1 ]]; then
    echo "============================================================================"
    date
    echo Only alert firing is DeadMansSwitch for openshift-monitoring
    echo "$openshift_alerts"
    echo "----------------------------------------------------------------------------"
    echo "Following alerts are firing for ${NAMESPACE_PREFIX}operator-observability:"
    echo "$rhoam_alerts"
    echo "============================================================================"
    echo "Following alerts are pending for ${NAMESPACE_PREFIX}operator-observability:"
    echo "$rhoam_alerts_pending"
    echo "============================================================================"
  else
    echo "============================================================================"
    echo "Following alerts are firing:"
    date
    echo "$all_alerts"
    echo "============================================================================"
    echo "Following alerts are pending:"
    date
    echo "$all_alerts_pending"
    echo "============================================================================"
  fi

  sleep 5

}

for product_name in "${products[@]}"; do
  if [[ "$1" != "$product_name" ]] && [[ "$1" != "" ]]; then
    continue
  fi

  # Loop over each monitoring source
  for source_name in "${!monitoring_sources[@]}"; do
    source_data="${monitoring_sources[$source_name]}"

    # Loop over each alert state to report on
    for alert_state in "${alert_states[@]}"; do
      # Generate a report for the current product, alert state, and monitoring source
      if [ $product_name == "rh-sso" ] || [ $product_name == "user-sso" ]; then
        echo "$source_data" |
          jq -r --arg state "$alert_state" --arg product "$product_name" '.data.alerts[] | select(.state==$state and (.labels.namespace==$product or .labels.namespace==($product+"-operator") or .labels.productName==$product or (.labels.alertname|test("Keycloak.+")))) | [.labels.alertname, .labels.namespace, .state, .activeAt] | @csv' >>"tmp-${source_name}-alert-${alert_state}-${product_name}-during-perf-testing-report.csv"
      elif [ $product_name == "3scale" ]; then
        echo "$source_data" |
          jq -r --arg state "$alert_state" --arg product "$product_name" '.data.alerts[] | select(.state==$state and (.labels.namespace==$product or .labels.namespace==($product+"-operator") or .labels.productName==$product or (.labels.alertname|test("ThreeScale.+")))) | [.labels.alertname, .labels.namespace, .state, .activeAt] | @csv' >>"tmp-${source_name}-alert-${alert_state}-${product_name}-during-perf-testing-report.csv"
      else
        echo "$source_data" |
          jq -r --arg state "$alert_state" --arg product "$product_name" '.data.alerts[] | select(.state==$state and (.labels.namespace==$product or .labels.namespace==($product+"-operator") or .labels.productName==$product)) | [.labels.alertname, .labels.namespace, .state, .activeAt] | @csv' >>"tmp-${source_name}-alert-${alert_state}-${product_name}-during-perf-testing-report.csv"
      fi

      # Generate a report for the current product, alert state, and monitoring source and make sure it's not empty
      report_data=$(echo "$source_data" | jq -r --arg state "$alert_state" --arg product "$product_name" '.data.alerts[] | select(.state==$state and (.labels.namespace==$product or .labels.namespace==($product+"-operator") or .labels.productName==$product or (.labels.alertname|test("Keycloak.+")))) | [.labels.alertname, .labels.namespace, .state, .activeAt] | @csv')
      echo "$report_data" >>"tmp-${source_name}-alert-${alert_state}-${product_name}-during-perf-testing-report.csv"
      
      file="tmp-${source_name}-alert-${alert_state}-${product_name}-during-perf-testing-report.csv"
      # Check if file is empty
      if [ ! -n "$(cat "$file")" ]; then
        echo "File $file is empty, removing it"
        rm "$file"
      else
        # Sort the report to remove duplicates
        sort -t',' -k 1,1 -u "tmp-${source_name}-alert-${alert_state}-${product_name}-during-perf-testing-report.csv" -o "${product_name}-alert-${alert_state}-during-perf-testing-report.csv"
      fi

    done
  done

  CHECK_NO_ALERTS
done

#If no args are passed in then run for all products
if (($# == 0)); then
  while :; do

    # Loop over each monitoring source
    for source_name in "${!monitoring_sources[@]}"; do
      source_data="${monitoring_sources[$source_name]}"

      # Loop over each alert state to report on
      for alert_state in "${alert_states[@]}"; do
        # Generate a report for the current alert state and monitoring source
        echo "$source_data" |
          jq -r --arg state "$alert_state" '.data.alerts[] | select(.state==$state) | [.labels.alertname, .state, .activeAt, .labels.severity] | @csv' >>"tmp-${source_name}-alert-${alert_state}-during-perf-testing-report.csv"

        # Sort the report to remove duplicates
        sort -t',' -k 1,1 -u "tmp-${source_name}-alert-${alert_state}-during-perf-testing-report.csv" -o "${source_name}-alert-${alert_state}-during-perf-testing-report.csv"
      done
    done

    CHECK_NO_ALERTS
  done
fi
