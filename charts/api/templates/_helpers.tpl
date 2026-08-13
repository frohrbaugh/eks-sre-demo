{{/* Chart name, overridable. */}}
{{- define "api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified app name. */}}
{{- define "api.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "api.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Selector labels.

These end up in spec.selector, which is IMMUTABLE. Keep this set minimal and
never add anything derived from the chart version or the image tag -- doing so
would make every upgrade attempt to mutate an immutable field.
*/}}
{{- define "api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "api.fullname" . }}
{{- end -}}

{{/* Full label set for metadata (safe to change between releases). */}}
{{- define "api.labels" -}}
{{ include "api.selectorLabels" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: eks-sre-demo
app.kubernetes.io/component: api
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "api.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
