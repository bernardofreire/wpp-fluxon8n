#!/bin/bash
# Sincroniza todas as abas do Google Sheets para arquivos CSV locais
# Uso: bash sync-sheets.sh

SHEET_ID="1FrLFvKhZQpyniQa4qMKfsgLJyrKXMDjpBPK8xw_JVn8"
BASE_URL="https://docs.google.com/spreadsheets/d/${SHEET_ID}/gviz/tq?tqx=out:csv&sheet="
OUTPUT_DIR="./sheets-data"

mkdir -p "$OUTPUT_DIR"

SHEETS=(
  "tenants_config"
  "Clients"
  "pizza_sizes"
  "pizza_flavors"
  "pizza_borders"
  "Order%20List"
  "horario_funcionamento"
  "Worksheet"
)

FILENAMES=(
  "tenants_config.csv"
  "Clients.csv"
  "pizza_sizes.csv"
  "pizza_flavors.csv"
  "pizza_borders.csv"
  "Order_List.csv"
  "horario_funcionamento.csv"
  "Worksheet_catalog.csv"
)

echo "Sincronizando planilhas..."
for i in "${!SHEETS[@]}"; do
  url="${BASE_URL}${SHEETS[$i]}"
  file="${OUTPUT_DIR}/${FILENAMES[$i]}"
  curl -sL "$url" -o "$file"
  if [ $? -eq 0 ] && [ -s "$file" ]; then
    echo "  OK: ${FILENAMES[$i]}"
  else
    echo "  ERRO: ${FILENAMES[$i]}"
  fi
done
echo "Concluido! Arquivos em ${OUTPUT_DIR}/"
