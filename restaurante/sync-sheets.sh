#!/bin/bash
# Sincroniza abas do Google Sheets do restaurante para CSV
# Uso: bash sync-sheets.sh

SHEET_ID="1KplKX83zwTk3DSrOVE4SELY68xo4gwn7PAhnJALVXfY"
BASE_URL="https://docs.google.com/spreadsheets/d/${SHEET_ID}/gviz/tq?tqx=out:csv&sheet="
OUTPUT_DIR="./sheets-data"

mkdir -p "$OUTPUT_DIR"

SHEETS=(
  "tenants_config"
  "Clients"
  "Order%20List"
  "horario_funcionamento"
  "Worksheet"
  "demo_sheet"
)

FILENAMES=(
  "tenants_config.csv"
  "Clients.csv"
  "Order_List.csv"
  "horario_funcionamento.csv"
  "Worksheet_catalog.csv"
  "demo_sheet.csv"
)

echo "Sincronizando planilhas do restaurante..."
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
