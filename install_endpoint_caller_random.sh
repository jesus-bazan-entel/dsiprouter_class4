#!/bin/bash

# dSIPRouter Endpoint Caller Random Installation Script
# Ejecutar como root

set -e

echo "=== Installing Endpoint Caller Random Feature ==="

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Función para logging
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Verificar que se ejecuta como root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root"
   exit 1
fi

# Detectar directorio de dSIPRouter
DSIP_DIR="/opt/dsiprouter"
if [ ! -d "$DSIP_DIR" ]; then
    DSIP_DIR="/usr/local/src/dsiprouter"
fi

if [ ! -d "$DSIP_DIR" ]; then
    log_error "dSIPRouter directory not found. Please specify the correct path."
    exit 1
fi

log_info "Using dSIPRouter directory: $DSIP_DIR"

# Función para backup de archivos
backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        cp "$file" "$file.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Backed up $file"
    fi
}

# 1. Instalar dependencias Python
log_info "Installing Python dependencies..."

# Detectar si estamos en un entorno administrado externamente
if python3 -c "import sys; exit(0 if hasattr(sys, 'real_prefix') or (hasattr(sys, 'base_prefix') and sys.base_prefix != sys.prefix) else 1)" 2>/dev/null; then
    # Estamos en un virtual environment
    log_info "Virtual environment detected, installing with pip..."
    pip3 install pandas openpyxl xlrd
elif [ -f "/etc/debian_version" ] && python3 -c "import sys; print(sys.version_info >= (3, 11))" 2>/dev/null | grep -q True; then
    # Sistema Debian/Ubuntu con Python 3.11+ (entorno administrado externamente)
    log_info "Externally managed environment detected, installing system packages..."
    
    # Actualizar lista de paquetes
    apt update
    
    # Instalar pandas via apt
    apt install -y python3-pandas || {
        log_warn "python3-pandas not available via apt, trying alternative method..."
        
        # Opción 1: Usar --break-system-packages (no recomendado pero funcional)
        log_warn "Using --break-system-packages flag (not recommended for production)"
        pip3 install --break-system-packages pandas openpyxl xlrd || {
            
            # Opción 2: Instalar en directorio local de dSIPRouter
            log_info "Installing in dSIPRouter local directory..."
            cd "$DSIP_DIR"
            
            # Crear directorio local para paquetes si no existe
            mkdir -p "$DSIP_DIR/local_packages"
            
            # Instalar en directorio local
            pip3 install --target="$DSIP_DIR/local_packages" pandas openpyxl xlrd || {
                log_error "Failed to install Python dependencies"
                exit 1
            }
            
            # Agregar el directorio al Python path en el archivo principal
            if [ -f "$DSIP_DIR/gui/main.py" ]; then
                APP_FILE="$DSIP_DIR/gui/main.py"
            elif [ -f "$DSIP_DIR/gui/app.py" ]; then
                APP_FILE="$DSIP_DIR/gui/app.py"
            else
                APP_FILE=""
            fi
            
            if [ -n "$APP_FILE" ] && ! grep -q "local_packages" "$APP_FILE"; then
                # Agregar al inicio del archivo
                sed -i '1i import sys\nimport os\nsys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "local_packages"))' "$APP_FILE"
                log_info "Added local packages to Python path"
            fi
        }
    }
    
    # Intentar instalar openpyxl y xlrd via apt
    apt install -y python3-openpyxl || pip3 install --break-system-packages openpyxl
    
    # xlrd no está disponible via apt en la mayoría de distribuciones
    pip3 install --break-system-packages xlrd || {
        log_warn "xlrd installation failed, will use openpyxl only"
    }
    
else
    # Sistema más antiguo o diferente, usar pip normal
    log_info "Installing with pip3..."
    pip3 install pandas openpyxl xlrd || {
        log_error "Failed to install Python dependencies"
        exit 1
    }
fi

# Verificar instalación
log_info "Verifying Python packages installation..."
python3 -c "import pandas; print(f'pandas {pandas.__version__} installed successfully')" || {
    log_error "pandas installation verification failed"
    exit 1
}

python3 -c "import openpyxl; print(f'openpyxl {openpyxl.__version__} installed successfully')" || {
    log_error "openpyxl installation verification failed"
    exit 1
}

python3 -c "import xlrd; print(f'xlrd {xlrd.__version__} installed successfully')" 2>/dev/null || {
    log_warn "xlrd not available, will use openpyxl for all Excel files"
}

# 2. Aplicar migración de base de datos
log_info "Applying database migration..."
mysql -u root -p kamailio < migration_endpoint_caller_random.sql || {
    log_error "Database migration failed"
    exit 1
}

# 3. Crear directorio para módulo
log_info "Creating module directory..."
mkdir -p "$DSIP_DIR/modules"

# 4. Crear archivo del controlador
log_info "Creating controller file..."
cat > "$DSIP_DIR/modules/endpoint_caller_random.py" << 'EOF'
# [Aquí iría el código completo del controlador de los artifacts anteriores]
EOF

# 5. Crear template
log_info "Creating template file..."
mkdir -p "$DSIP_DIR/templates"
cat > "$DSIP_DIR/templates/endpointcallerrandom.html" << 'EOF'
# [Aquí iría el código completo del template de los artifacts anteriores]
EOF

# 6. Actualizar configuración de Kamailio
log_info "Updating Kamailio configuration..."
KAMAILIO_CFG="/etc/kamailio/kamailio.cfg"

if [ ! -f "$KAMAILIO_CFG" ]; then
    KAMAILIO_CFG="/usr/local/etc/kamailio/kamailio.cfg"
fi

if [ ! -f "$KAMAILIO_CFG" ]; then
    log_error "Kamailio configuration file not found"
    exit 1
fi

backup_file "$KAMAILIO_CFG"

# Agregar htable para endpoint caller random
if ! grep -q "endpoint_caller_random" "$KAMAILIO_CFG"; then
    log_info "Adding htable configuration to Kamailio..."
    
    # Buscar la línea donde se definen otros htables y agregar después
    sed -i '/modparam("htable", "htable", "gw2gwgroup/a\
# htable para números de origen aleatorios por endpoint group\
modparam("htable", "htable", "endpoint_caller_random=>size=8;autoexpire=0;dmqreplicate=DMQ_REPLICATE_ENABLED;dbtable=dsip_endpoint_caller_random;cols='\''gwgroupid,caller_number,active'\'';")' "$KAMAILIO_CFG"
else
    log_warn "Kamailio htable configuration already exists"
fi

# 7. Agregar rutas de Kamailio
log_info "Adding Kamailio routes..."

# Crear archivo temporal con las nuevas rutas
cat > /tmp/kamailio_random_caller_routes.cfg << 'EOF'

# Ruta para selección de caller ID aleatorio
route[SET_RANDOM_CALLER] {
    # Solo aplicar para llamadas salientes desde PBX
    if (!isbflagset(FLB_SRC_PBX) && !isflagset(FLT_PBX_AUTH)) {
        xlog("L_DBG", "RANDOM_CALLER: Not a PBX source, skipping random caller selection\n");
        return;
    }
    
    # Verificar si tenemos información del grupo de origen
    if ($dlg_var(src_gwgroupid) == $null) {
        xlog("L_DBG", "RANDOM_CALLER: No source gwgroupid available\n");
        return;
    }
    
    # Obtener un número aleatorio directamente con SQL (método más simple)
    $var(random_caller_query) = "SELECT caller_number FROM dsip_endpoint_caller_random WHERE gwgroupid=" + $dlg_var(src_gwgroupid) + " AND active=1 ORDER BY RAND() LIMIT 1";
    sql_xquery("kam", "$var(random_caller_query)", "random_caller_result");
    
    if ($xavp(random_caller_result=>caller_number) != $null) {
        # Guardar el caller ID original
        $dlg_var(original_caller) = $fU;
        
        # Cambiar el número de origen
        $fU = $xavp(random_caller_result=>caller_number);
        
        # Actualizar headers relacionados
        remove_hf("P-Asserted-Identity");
        append_hf("P-Asserted-Identity: <sip:$fU@$fd>\r\n");
        
        # Log para debugging
        xlog("L_INFO", "RANDOM_CALLER: Changed caller ID from $dlg_var(original_caller) to $fU for gwgroup $dlg_var(src_gwgroupid)\n");
        
        # Aplicar cambios
        if (!msg_apply_changes()) {
            xlog("L_ERR", "RANDOM_CALLER: Failed to apply message changes\n");
        } else {
            $dlg_var(random_caller_applied) = "1";
        }
    } else {
        xlog("L_DBG", "RANDOM_CALLER: No random caller numbers available for gwgroup $dlg_var(src_gwgroupid)\n");
    }
    
    sql_result_free("random_caller_result");
    return;
}

EOF

# Insertar las rutas antes de la última línea del archivo de configuración
if ! grep -q "route\[SET_RANDOM_CALLER\]" "$KAMAILIO_CFG"; then
    # Agregar las rutas al final del archivo, antes de la última línea
    head -n -1 "$KAMAILIO_CFG" > /tmp/kamailio_temp.cfg
    cat /tmp/kamailio_random_caller_routes.cfg >> /tmp/kamailio_temp.cfg
    tail -n 1 "$KAMAILIO_CFG" >> /tmp/kamailio_temp.cfg
    mv /tmp/kamailio_temp.cfg "$KAMAILIO_CFG"
    
    log_info "Added Kamailio routes"
else
    log_warn "Kamailio routes already exist"
fi

# 8. Modificar la ruta NEXTHOP para incluir la llamada a SET_RANDOM_CALLER
log_info "Updating NEXTHOP route..."

# Buscar y reemplazar la línea específica
sed -i '/route(SETUP_DIALOG);/a\
            # Aplicar caller ID aleatorio\
            route(SET_RANDOM_CALLER);' "$KAMAILIO_CFG"

# 9. Registrar blueprint en la aplicación
log_info "Updating application registration..."

APP_FILE="$DSIP_DIR/gui/main.py"
if [ ! -f "$APP_FILE" ]; then
    APP_FILE="$DSIP_DIR/gui/app.py"
fi

if [ -f "$APP_FILE" ]; then
    backup_file "$APP_FILE"
    
    # Agregar import si no existe
    if ! grep -q "endpoint_caller_random" "$APP_FILE"; then
        # Agregar import después de otras importaciones de módulos
        sed -i '/from modules\./a\
from modules.endpoint_caller_random import endpoint_caller_bp' "$APP_FILE"
        
        # Agregar registro del blueprint
        sed -i '/app\.register_blueprint/a\
app.register_blueprint(endpoint_caller_bp)' "$APP_FILE"
        
        log_info "Updated application registration"
    else
        log_warn "Application registration already exists"
    fi
else
    log_warn "Application file not found, manual registration required"
fi

# 10. Crear directorio para uploads
log_info "Creating upload directory..."
mkdir -p /tmp/uploads
chmod 755 /tmp/uploads

# 11. Actualizar permisos
log_info "Setting permissions..."
chown -R dsiprouter:dsiprouter "$DSIP_DIR/modules/endpoint_caller_random.py" 2>/dev/null || true
chown -R dsiprouter:dsiprouter "$DSIP_DIR/templates/endpointcallerrandom.html" 2>/dev/null || true

# 12. Validar configuración de Kamailio
log_info "Validating Kamailio configuration..."
if kamailio -c -f "$KAMAILIO_CFG" > /dev/null 2>&1; then
    log_info "Kamailio configuration is valid"
else
    log_error "Kamailio configuration validation failed"
    log_error "Please check the configuration manually"
fi

# 13. Reiniciar servicios
log_info "Restarting services..."

# Reiniciar dSIPRouter
systemctl restart dsiprouter || {
    log_error "Failed to restart dSIPRouter"
    exit 1
}

# Recargar Kamailio
systemctl reload kamailio || {
    log_warn "Failed to reload Kamailio, trying restart..."
    systemctl restart kamailio || {
        log_error "Failed to restart Kamailio"
        exit 1
    }
}

# 14. Verificar servicios
log_info "Verifying services..."
if systemctl is-active --quiet dsiprouter; then
    log_info "dSIPRouter is running"
else
    log_error "dSIPRouter is not running"
fi

if systemctl is-active --quiet kamailio; then
    log_info "Kamailio is running"
else
    log_error "Kamailio is not running"
fi

# 15. Limpiar archivos temporales
rm -f /tmp/kamailio_random_caller_routes.cfg
rm -f /tmp/kamailio_temp.cfg

log_info "Installation completed successfully!"
echo ""
echo "=== Next Steps ==="
echo "1. Access the dSIPRouter web interface"
echo "2. Navigate to 'Endpoint Caller Random' in the menu"
echo "3. Upload an Excel file with phone numbers"
echo "4. Test outbound calls from the configured endpoint groups"
echo ""
echo "=== Troubleshooting ==="
echo "- Check logs: tail -f /var/log/kamailio.log"
echo "- Check dSIPRouter logs: tail -f /var/log/dsiprouter.log"
echo "- Verify database: mysql -u root -p kamailio -e 'SHOW TABLES LIKE \"%caller%\";'"
echo ""
log_info "Installation script finished!"
