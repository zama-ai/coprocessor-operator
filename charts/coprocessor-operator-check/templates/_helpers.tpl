{{/*
Expand the name of the chart.
*/}}
{{- define "coprocessor-operator-check.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "coprocessor-operator-check.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "coprocessor-operator-check.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "coprocessor-operator-check.labels" -}}
helm.sh/chart: {{ include "coprocessor-operator-check.chart" . }}
{{ include "coprocessor-operator-check.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "coprocessor-operator-check.selectorLabels" -}}
app.kubernetes.io/name: {{ include "coprocessor-operator-check.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Job name unique per release and revision, so a check can be rerun right away while the Job of
the previous run is kept until ttlSecondsAfterFinished. The prefix is truncated (not the suffix)
to keep the name, also used as the job-name label value, under 63 chars.
Usage: include "coprocessor-operator-check.jobName" (dict "context" . "component" "infra-config")
*/}}
{{- define "coprocessor-operator-check.jobName" -}}
{{- $prefix := include "coprocessor-operator-check.fullname" .context | trunc 40 | trimSuffix "-" }}
{{- printf "%s-%s-%d" $prefix .component (int .context.Release.Revision) }}
{{- end }}

{{/*
Check pod labels, including the release revision to select the logs of a given run
*/}}
{{- define "coprocessor-operator-check.podLabels" -}}
app: coprocessor-operator-check
{{ include "coprocessor-operator-check.selectorLabels" . }}
coprocessor-operator-check/revision: {{ .Release.Revision | quote }}
{{- end }}

{{/*
Runs a check script in a subshell and fails the container with the script's exit code, so that a
failing check fails the hook Job and blocks the release. Not written as "( script ) || ..." since
that would disable "set -e" in the script.
Usage: include "coprocessor-operator-check.runCheck" (dict "name" "k8s-check" "script" .Values.checks.k8s.script)
*/}}
{{- define "coprocessor-operator-check.runCheck" -}}
(
{{- .script | nindent 2 }}
)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "{{ .name }} exited with error (exit code $rc)"
  exit "$rc"
fi
{{- end }}
