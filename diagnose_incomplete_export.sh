#!/bin/bash
# Script para diagnosticar exportación incompleta

echo "=== DIAGNÓSTICO DE EXPORTACIÓN INCOMPLETA ==="
echo "Fecha: $(date)"
echo

# 1. Verificar archivos CSV generados
echo "1. Archivos CSV generados:"
echo "=========================="
if [ -d "/tmp/cdr_exports" ]; then
    ls -la /tmp/cdr_exports/
    echo
    
    # Analizar el archivo más reciente
    newest_csv=$(ls -t /tmp/cdr_exports/*.csv 2>/dev/null | head -1)
    if [ -n "$newest_csv" ]; then
        echo "Archivo más reciente: $newest_csv"
        echo "Tamaño: $(stat -c%s "$newest_csv") bytes"
        echo "Líneas totales: $(wc -l < "$newest_csv")"
        echo "Líneas de datos (sin header): $(($(wc -l < "$newest_csv") - 1))"
        echo
        
        echo "Primeras 5 líneas:"
        head -5 "$newest_csv"
        echo
        
        echo "Últimas 5 líneas:"
        tail -5 "$newest_csv"
        echo
    else
        echo "No se encontraron archivos CSV"
    fi
else
    echo "❌ Directorio /tmp/cdr_exports no existe"
fi

# 2. Comparar con total de CDRs en base de datos
echo "2. Comparación con base de datos:"
echo "================================"
python3 -c "
import sys
sys.path.insert(0, '/opt/dsiprouter/gui')

try:
    from database import startSession
    
    db = startSession()
    
    # Total CDRs
    total_cdrs = db.execute('SELECT COUNT(*) FROM cdrs').scalar()
    print(f'Total CDRs en base de datos: {total_cdrs}')
    
    # CDRs de los últimos 30 días
    recent_cdrs = db.execute('SELECT COUNT(*) FROM cdrs WHERE call_start_time >= DATE_SUB(NOW(), INTERVAL 30 DAY)').scalar()
    print(f'CDRs últimos 30 días: {recent_cdrs}')
    
    # CDRs de la última semana
    week_cdrs = db.execute('SELECT COUNT(*) FROM cdrs WHERE call_start_time >= DATE_SUB(NOW(), INTERVAL 7 DAY)').scalar()
    print(f'CDRs última semana: {week_cdrs}')
    
    # CDRs del último día
    day_cdrs = db.execute('SELECT COUNT(*) FROM cdrs WHERE call_start_time >= DATE_SUB(NOW(), INTERVAL 1 DAY)').scalar()
    print(f'CDRs último día: {day_cdrs}')
    
    # Verificar endpoint groups disponibles
    groups = db.execute('SELECT id, description FROM dr_gw_lists WHERE type = 2 LIMIT 10').fetchall()
    print(f'\\nEndpoint groups disponibles:')
    for group in groups:
        print(f'  ID: {group[0]}, Desc: {group[1]}')
        
        # CDRs para este grupo específico
        group_cdrs = db.execute('''
            SELECT COUNT(*) FROM cdrs t1
            JOIN dr_gw_lists t2 ON (t1.src_gwgroupid = t2.id OR t1.dst_gwgroupid = t2.id)
            WHERE t2.id = :gwgroupid
        ''', {'gwgroupid': group[0]}).scalar()
        print(f'    CDRs para este grupo: {group_cdrs}')
    
    db.close()
    
except Exception as e:
    print(f'Error: {e}')
    import traceback
    traceback.print_exc()
"

# 3. Verificar logs de la última exportación
echo
echo "3. Logs de la última exportación:"
echo "================================"
journalctl -u dsiprouter --since "10 minutes ago" | grep -E "\[CDR_EXPORT\]|\[CSV_GEN\]" | tail -20

# 4. Verificar límites en la consulta
echo
echo "4. Verificando límites en consulta SQL:"
echo "======================================"
grep -n "LIMIT" /opt/dsiprouter/gui/modules/api/api_routes.py | grep -A2 -B2 "generateCSVExport\|CDR"

echo
echo "=== ANÁLISIS COMPLETADO ==="
echo
echo "POSIBLES CAUSAS DE EXPORTACIÓN INCOMPLETA:"
echo "1. Límite LIMIT en la consulta SQL (probablemente 10000)"
echo "2. Timeout de la consulta de base de datos"
echo "3. Filtros involuntarios por endpoint group"
echo "4. Problemas de memoria durante la exportación"
echo "5. JOINs que excluyen algunos registros"
echo
echo "VERIFICAR:"
echo "- ¿Cuántos CDRs esperabas vs cuántos se exportaron?"
echo "- ¿Los CDRs faltantes son de fechas específicas?"
echo "- ¿Los CDRs pertenecen a endpoint groups específicos?"
