# dsiprouter/modules/endpoint_caller_random.py

import sys
if sys.path[0] != '/etc/dsiprouter/gui':
    sys.path.insert(0, '/etc/dsiprouter/gui')

import os
import pandas as pd
from flask import Blueprint, render_template, request, redirect, url_for, flash, jsonify, send_file
from werkzeug.utils import secure_filename
from sqlalchemy import text
from shared import debugException
from database import startSession, DummySession
import re
import tempfile
from datetime import datetime

endpoint_caller_bp = Blueprint('endpoint_caller_random', __name__)

ALLOWED_EXTENSIONS = {'xls', 'xlsx'}
UPLOAD_FOLDER = '/opt/dsiprouter/uploads'
MAX_FILE_SIZE = 10 * 1024 * 1024  # 10MB

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

def validate_phone_number(number):
    """Validar formato de número telefónico"""
    cleaned = re.sub(r'[^\d+]', '', str(number))
    pattern = r'^\+?[1-9]\d{6,14}$'
    return re.match(pattern, cleaned) is not None

@endpoint_caller_bp.route('/endpointcallerrandom')
def showEndpointCallerRandom():
    """Mostrar la página principal de gestión"""
    try:
        db = startSession()
        
        # Obtener solo los endpoint groups (type:9)
        endpoint_groups = db.execute(
            text("""
                SELECT g.id, 
                       SUBSTRING_INDEX(SUBSTRING_INDEX(g.description, 'name:', -1), ',', 1) as name
                FROM dr_gw_lists g 
                WHERE g.description LIKE '%type:9%'
                ORDER BY name
            """)
        ).fetchall()
        
        # Obtener números configurados por grupo
        configured_numbers = db.execute(
            text("""
                SELECT 
                    e.gwgroupid, 
                    SUBSTRING_INDEX(SUBSTRING_INDEX(g.description, 'name:', -1), ',', 1) as group_name,
                    COUNT(e.caller_number) as total_numbers,
                    COUNT(CASE WHEN e.active = 1 THEN 1 END) as active_numbers,
                    MAX(e.updated_at) as updated_at
                FROM dsip_endpoint_caller_random e
                JOIN dr_gw_lists g ON e.gwgroupid = g.id
                WHERE g.description LIKE '%type:9%'
                GROUP BY e.gwgroupid, g.description
                ORDER BY group_name
            """)
        ).fetchall()
        
        db.close()
        
        return render_template('endpointcallerrandom.html', 
                             endpoint_groups=endpoint_groups,
                             configured_numbers=configured_numbers)
    except Exception as ex:
        debugException(ex)
        flash('Error loading endpoint caller random configuration', 'error')
        return redirect(url_for('index'))

@endpoint_caller_bp.route('/endpointcallerrandom/upload', methods=['POST'])
def uploadCallerNumbers():
    """Subir archivo Excel con números de origen"""
    try:
        if 'file' not in request.files:
            flash('No file selected', 'error')
            return redirect(url_for('endpoint_caller_random.showEndpointCallerRandom'))
        
        file = request.files['file']
        gwgroupid = request.form.get('gwgroupid')
        replace_existing = request.form.get('replace_existing') == 'on'
        
        if not gwgroupid or file.filename == '':
            flash('Must select an Endpoint Group and file', 'error')
            return redirect(url_for('endpoint_caller_random.showEndpointCallerRandom'))
        
        if file and allowed_file(file.filename):
            filename = secure_filename(file.filename)
            os.makedirs(UPLOAD_FOLDER, exist_ok=True)
            filepath = os.path.join(UPLOAD_FOLDER, f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{filename}")
            file.save(filepath)
            
            try:
                success_count, error_count, errors = process_excel_file(filepath, gwgroupid, replace_existing)
                os.remove(filepath)
                
                if success_count > 0:
                    flash(f'Successfully processed {success_count} numbers. Errors: {error_count}', 'success')
                    reload_kamailio_htable()
                else:
                    flash(f'No numbers processed. Errors: {error_count}', 'error')
                    
                for error in errors[:5]:
                    flash(f'Warning: {error}', 'warning')
                    
            except Exception as ex:
                if os.path.exists(filepath):
                    os.remove(filepath)
                raise ex
        else:
            flash('Invalid file type. Use .xls or .xlsx files', 'error')
            
    except Exception as ex:
        debugException(ex)
        flash('Error processing file', 'error')
    
    return redirect(url_for('endpoint_caller_random.showEndpointCallerRandom'))

def process_excel_file(filepath, gwgroupid, replace_existing):
    """Procesar archivo Excel"""
    success_count = 0
    error_count = 0
    errors = []
    
    db = startSession()
    
    try:
        # Leer Excel con múltiples engines
        df = None
        for engine in ['openpyxl', 'xlrd', None]:
            try:
                df = pd.read_excel(filepath, engine=engine)
                break
            except Exception as e:
                if engine is None:
                    errors.append(f"Could not read Excel file: {str(e)}")
                    return success_count, error_count + 1, errors
                continue
        
        if df.empty:
            errors.append("Excel file is empty")
            return success_count, error_count + 1, errors
        
        # Buscar columna con números
        number_column = None
        search_terms = ['number', 'phone', 'caller', 'telefono', 'numero']
        
        for col in df.columns:
            if any(term in str(col).lower() for term in search_terms):
                number_column = col
                break
        
        if number_column is None:
            number_column = df.columns[0]
        
        # Reemplazar existentes si se solicita
        if replace_existing:
            db.execute(
                text("DELETE FROM dsip_endpoint_caller_random WHERE gwgroupid = :gwgroupid"),
                {'gwgroupid': gwgroupid}
            )
            db.commit()
        
        # Procesar números
        for index, row in df.iterrows():
            try:
                raw_number = row[number_column]
                if pd.isna(raw_number) or str(raw_number).strip() == '':
                    continue
                
                cleaned_number = re.sub(r'[^\d+]', '', str(raw_number))
                
                if validate_phone_number(cleaned_number):
                    # Verificar si existe
                    existing = db.execute(
                        text("SELECT id FROM dsip_endpoint_caller_random WHERE gwgroupid = :gwgroupid AND caller_number = :number"),
                        {'gwgroupid': gwgroupid, 'number': cleaned_number}
                    ).fetchone()
                    
                    if not existing:
                        db.execute(
                            text("INSERT INTO dsip_endpoint_caller_random (gwgroupid, caller_number) VALUES (:gwgroupid, :number)"),
                            {'gwgroupid': gwgroupid, 'number': cleaned_number}
                        )
                        success_count += 1
                    else:
                        error_count += 1
                else:
                    errors.append(f'Invalid number in row {index + 2}: {raw_number}')
                    error_count += 1
                    
            except Exception as ex:
                errors.append(f'Error in row {index + 2}: {str(ex)}')
                error_count += 1
        
        db.commit()
        
    except Exception as ex:
        db.rollback()
        errors.append(f'Error processing file: {str(ex)}')
        error_count += 1
    finally:
        db.close()
    
    return success_count, error_count, errors

def reload_kamailio_htable():
    """Recargar htable en Kamailio"""
    try:
        import subprocess
        result = subprocess.run(['kamcmd', 'htable.reload', 'endpoint_caller_random'], 
                              capture_output=True, text=True, timeout=10)
        return result.returncode == 0
    except:
        return False

@endpoint_caller_bp.route('/endpointcallerrandom/delete/<int:gwgroupid>', methods=['POST'])
def deleteCallerNumbers(gwgroupid):
    """Eliminar números de un grupo"""
    try:
        db = startSession()
        
        deleted_count = db.execute(
            text("DELETE FROM dsip_endpoint_caller_random WHERE gwgroupid = :gwgroupid"),
            {'gwgroupid': gwgroupid}
        ).rowcount
        db.commit()
        db.close()
        
        if deleted_count > 0:
            reload_kamailio_htable()
            flash(f'Deleted {deleted_count} numbers', 'success')
        else:
            flash('No numbers found to delete', 'warning')
        
    except Exception as ex:
        debugException(ex)
        flash('Error deleting numbers', 'error')
    
    return redirect(url_for('endpoint_caller_random.showEndpointCallerRandom'))

@endpoint_caller_bp.route('/endpointcallerrandom/toggle/<int:gwgroupid>', methods=['POST'])
def toggleCallerNumbers(gwgroupid):
    """Activar/desactivar números"""
    try:
        db = startSession()
        active = request.form.get('active') == 'true'
        
        updated_count = db.execute(
            text("UPDATE dsip_endpoint_caller_random SET active = :active WHERE gwgroupid = :gwgroupid"),
            {'active': active, 'gwgroupid': gwgroupid}
        ).rowcount
        db.commit()
        db.close()
        
        if updated_count > 0:
            reload_kamailio_htable()
            status = 'activated' if active else 'deactivated'
            flash(f'{status.title()} {updated_count} numbers', 'success')
        
    except Exception as ex:
        debugException(ex)
        flash('Error updating numbers', 'error')
    
    return redirect(url_for('endpoint_caller_random.showEndpointCallerRandom'))

@endpoint_caller_bp.route('/endpointcallerrandom/numbers/<int:gwgroupid>')
def getCallerNumbers(gwgroupid):
    """Obtener números de un endpoint group específico via AJAX"""
    try:
        db = startSession()
        
        numbers = db.execute(
            text("""
                SELECT caller_number, active, created_at 
                FROM dsip_endpoint_caller_random 
                WHERE gwgroupid = :gwgroupid 
                ORDER BY created_at DESC
            """),
            {'gwgroupid': gwgroupid}
        ).fetchall()
        
        db.close()
        
        # Convertir a formato JSON
        numbers_list = []
        active_count = 0
        for number in numbers:
            numbers_list.append({
                'caller_number': number.caller_number,
                'active': bool(number.active),
                'created_at': number.created_at.strftime('%Y-%m-%d %H:%M') if number.created_at else 'N/A'
            })
            if number.active:
                active_count += 1
        
        summary = {
            'total': len(numbers_list),
            'active': active_count,
            'inactive': len(numbers_list) - active_count
        }
        
        return jsonify({
            'numbers': numbers_list,
            'summary': summary
        })
        
    except Exception as ex:
        debugException(ex)
        return jsonify({'error': str(ex)}), 500

@endpoint_caller_bp.route('/endpointcallerrandom/download/<int:gwgroupid>')
def downloadCallerNumbers(gwgroupid):
    """Descargar números en formato Excel"""
    try:
        db = startSession()
        
        # Obtener nombre del grupo
        group_info = db.execute(
            text("SELECT SUBSTRING_INDEX(SUBSTRING_INDEX(description, 'name:', -1), ',', 1) as name FROM dr_gw_lists WHERE id = :gwgroupid"),
            {'gwgroupid': gwgroupid}
        ).fetchone()
        
        if not group_info:
            flash('Endpoint group not found', 'error')
            return redirect(url_for('endpoint_caller_random.showEndpointCallerRandom'))
        
        # Obtener números
        numbers = db.execute(
            text("""
                SELECT caller_number, active, created_at, updated_at
                FROM dsip_endpoint_caller_random 
                WHERE gwgroupid = :gwgroupid 
                ORDER BY created_at ASC
            """),
            {'gwgroupid': gwgroupid}
        ).fetchall()
        
        db.close()
        
        if not numbers:
            flash('No numbers found for this endpoint group', 'warning')
            return redirect(url_for('endpoint_caller_random.showEndpointCallerRandom'))
        
        # Crear DataFrame
        data = []
        for number in numbers:
            data.append({
                'Caller Number': number.caller_number,
                'Status': 'Active' if number.active else 'Inactive',
                'Created': number.created_at.strftime('%Y-%m-%d %H:%M:%S') if number.created_at else '',
                'Updated': number.updated_at.strftime('%Y-%m-%d %H:%M:%S') if number.updated_at else ''
            })
        
        df = pd.DataFrame(data)
        
        # Crear archivo temporal
        with tempfile.NamedTemporaryFile(delete=False, suffix='.xlsx') as tmp_file:
            df.to_excel(tmp_file.name, index=False, engine='openpyxl')
            tmp_file_path = tmp_file.name
        
        # Nombre del archivo
        filename = f"caller_numbers_{group_info.name}_{gwgroupid}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.xlsx"
        
        def remove_file(response):
            try:
                os.unlink(tmp_file_path)
            except Exception:
                pass
            return response
        
        return send_file(
            tmp_file_path,
            as_attachment=True,
            download_name=filename,
            mimetype='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
        )
        
    except Exception as ex:
        debugException(ex)
        flash('Error downloading numbers', 'error')
        return redirect(url_for('endpoint_caller_random.showEndpointCallerRandom'))
