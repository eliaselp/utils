#!/bin/bash

# Script unificado de limpieza de RAM - Versión con menú interactivo con flechas
# Verificar que dialog esté instalado
if ! command -v dialog &> /dev/null; then
    echo "Dialog no está instalado. Instalando..."
    apt-get update && apt-get install -y dialog
fi

# Verificar que se ejecute con sudo
if [[ $EUID -ne 0 ]]; then
   echo -e "⚠️  Este script debe ejecutarse con sudo para funcionar correctamente" 
   echo -e "Ejecuta: sudo $0"
   exit 1
fi

# Función para mostrar uso de RAM
show_ram_usage() {
    dialog --title "USO ACTUAL DE MEMORIA RAM" \
           --msgbox "$(free -h)" 20 60
}

# Función para mostrar top de procesos
show_top_processes() {
    local procesos=$(ps aux --sort=-%mem | head -16 | awk 'NR==1 {printf "%-10s %-6s %-8s %-30s\n", "PID", "RAM%", "MEM(MB)", "COMANDO"} 
                                          NR>1 {printf "%-10s %-6s %-8s %-30s\n", $2, $4, $6/1024, substr($11,1,30)}')
    dialog --title "TOP 15 PROCESOS QUE MÁS RAM CONSUMEN" \
           --msgbox "$procesos" 25 80
}

# Función para limpieza ligera
clean_light() {
    {
        echo "0"
        echo "XXX"
        echo "Iniciando limpieza ligera..."
        echo "XXX"
        
        sleep 1
        echo "20"
        echo "XXX"
        echo "[1/5] Limpiando caché de memoria..."
        echo "XXX"
        sync
        echo 3 > /proc/sys/vm/drop_caches
        
        sleep 1
        echo "40"
        echo "XXX"
        echo "[2/5] Optimizando swap..."
        echo "XXX"
        swapoff -a 2>/dev/null && swapon -a 2>/dev/null
        
        sleep 1
        echo "60"
        echo "XXX"
        echo "[3/5] Limpiando cachés de usuario..."
        echo "XXX"
        if [ -d /home/*/.cache ]; then
            find /home/*/.cache -type f -atime +1 -delete 2>/dev/null
        fi
        rm -rf /tmp/* 2>/dev/null
        
        sleep 1
        echo "80"
        echo "XXX"
        echo "[4/5] Limpiando procesos zombi..."
        echo "XXX"
        zombies=$(ps aux | awk '$8=="Z" {print $2}')
        for zombie in $zombies; do
            kill -9 $zombie 2>/dev/null
        done
        
        sleep 1
        echo "100"
        echo "XXX"
        echo "[5/5] Limpiando logs viejos..."
        echo "XXX"
        journalctl --vacuum-time=3d 2>/dev/null
        
        sleep 1
    } | dialog --title "LIMPIEZA LIGERA DE RAM" \
               --gauge "Procesando..." 10 60 0
    
    dialog --title "RESULTADO" \
           --msgbox "✅ Limpieza ligera completada exitosamente!\n\n$(free -h)" 15 60
}

# Función para limpieza agresiva
clean_aggressive() {
    # Mostrar advertencia
    dialog --title "⚠️ ADVERTENCIA ⚠️" \
           --yesno "Este modo cerrará aplicaciones y procesos que consumen mucha RAM.\n\nSe recomienda guardar todo tu trabajo antes de continuar.\n\n¿Estás seguro de continuar?" 12 60
    
    if [ $? -ne 0 ]; then
        dialog --title "CANCELADO" --msgbox "Operación cancelada por el usuario." 6 40
        return
    fi
    
    # Mostrar procesos antes de limpiar
    local procesos=$(ps aux --sort=-%mem | head -16 | awk 'NR==1 {printf "%-10s %-6s %-8s %-30s\n", "PID", "RAM%", "MEM(MB)", "COMANDO"} 
                                          NR>1 {printf "%-10s %-6s %-8s %-30s\n", $2, $4, $6/1024, substr($11,1,30)}')
    dialog --title "PROCESOS ACTUALES" \
           --msgbox "$procesos\n\nSe procederá a cerrar los procesos más pesados..." 25 80
    
    {
        echo "0"
        echo "XXX"
        echo "Iniciando limpieza agresiva..."
        echo "XXX"
        
        sleep 1
        echo "14"
        echo "XXX"
        echo "[1/7] Sincronizando y limpiando caché..."
        echo "XXX"
        sync
        echo 3 > /proc/sys/vm/drop_caches
        echo 1 > /proc/sys/vm/drop_caches
        
        sleep 1
        echo "28"
        echo "XXX"
        echo "[2/7] Optimizando swap..."
        echo "XXX"
        swapoff -a && swapon -a
        
        sleep 1
        echo "42"
        echo "XXX"
        echo "[3/7] Matando procesos con alto consumo de RAM (>500MB)..."
        echo "XXX"
        ps aux | awk '$6 > 500000 && $2 != "PID" {print $2}' | while read pid; do
            kill -9 $pid 2>/dev/null
        done
        
        sleep 1
        echo "56"
        echo "XXX"
        echo "[4/7] Cerrando aplicaciones comunes..."
        echo "XXX"
        apps=("firefox" "chrome" "chromium" "brave" "slack" "discord" "spotify" "code" "node" "electron" "telegram" "zoom" "thunderbird")
        for app in "${apps[@]}"; do
            pkill -9 "$app" 2>/dev/null
        done
        
        sleep 1
        echo "70"
        echo "XXX"
        echo "[5/7] Limpiando cachés del sistema..."
        echo "XXX"
        rm -rf /home/*/.cache/* 2>/dev/null
        rm -rf /root/.cache/* 2>/dev/null
        rm -rf /tmp/* 2>/dev/null
        rm -rf /var/tmp/* 2>/dev/null
        
        sleep 1
        echo "84"
        echo "XXX"
        echo "[6/7] Limpiando procesos zombi y huérfanos..."
        echo "XXX"
        zombies=$(ps aux | awk '$8=="Z" {print $2}')
        for zombie in $zombies; do
            kill -9 $zombie 2>/dev/null
        done
        
        sleep 1
        echo "98"
        echo "XXX"
        echo "[7/7] Limpiando logs antiguos..."
        echo "XXX"
        journalctl --vacuum-size=50M 2>/dev/null
        find /var/log -name "*.log" -type f -mtime +7 -delete 2>/dev/null
        
        sleep 1
        echo "100"
        echo "XXX"
        echo "¡Completado!"
        echo "XXX"
    } | dialog --title "LIMPIEZA AGRESIVA DE RAM" \
               --gauge "Procesando..." 10 60 0
    
    dialog --title "RESULTADO" \
           --msgbox "✅ Limpieza agresiva completada exitosamente!\n\n$(free -h)\n\n💡 Nota: Algunas aplicaciones pueden haber sido cerradas.\n   Vuelve a abrirlas normalmente cuando las necesites." 20 60
}

# Función para diagnóstico completo
diagnostic() {
    local diagnostico=""
    
    diagnostico+="📊 MEMORIA RAM:\n"
    diagnostico+="$(free -h)\n\n"
    
    diagnostico+="💾 MEMORIA SWAP:\n"
    diagnostico+="$(swapon --show 2>/dev/null || echo "No hay swap activado")\n\n"
    
    diagnostico+="🔥 TOP 15 PROCESOS POR CONSUMO DE RAM:\n"
    diagnostico+="$(ps aux --sort=-%mem | head -16 | awk 'NR==1 {printf "%-10s %-6s %-8s %-6s %-30s\n", "PID", "RAM%", "MEM(MB)", "CPU%", "COMANDO"} 
                                          NR>1 {printf "%-10s %-6s %-8s %-6s %-30s\n", $2, $4, $6/1024, $3, substr($11,1,30)}')\n\n"
    
    diagnostico+="🧟 PROCESOS ZOMBI:\n"
    diagnostico+="$(ps aux | awk '$8=="Z" {print "PID: " $2 " | CMD: " $11}' || echo "No hay procesos zombi")\n\n"
    
    diagnostico+="💿 USO DE DISCO:\n"
    diagnostico+="$(df -h | grep -E "^/dev/" | head -5)\n"
    
    dialog --title "DIAGNÓSTICO DEL SISTEMA" \
           --msgbox "$diagnostico" 30 90
}

# Función para monitoreo en tiempo real
live_monitor() {
    dialog --title "MONITOREO EN TIEMPO REAL" \
           --infobox "Iniciando htop...\nPresiona F10 o 'q' para salir" 5 50
    sleep 2
    clear
    if command -v htop >/dev/null 2>&1; then
        htop
    else
        echo "htop no está instalado. Instalando..."
        apt-get update && apt-get install -y htop
        htop
    fi
}

# Menú principal con flechas
main_menu() {
    while true; do
        opcion=$(dialog --clear \
            --title "SISTEMA DE OPTIMIZACIÓN DE MEMORIA RAM" \
            --menu "Estado actual de la memoria:\n$(free -h | grep -E "Mem|Swap")\n\nSelecciona una opción con las flechas ↑ ↓ y presiona Enter:" \
            20 70 8 \
            "1" "Limpieza Ligera - Limpia caché y swap" \
            "2" "Limpieza Agresiva - Cierra apps y limpia todo" \
            "3" "Diagnóstico - Analiza el sistema completo" \
            "4" "Monitor en vivo - htop en tiempo real" \
            "5" "Top procesos - Muestra procesos más pesados" \
            "6" "Salir - Cerrar el programa" \
            2>&1 >/dev/tty)
        
        case $opcion in
            1)
                clean_light
                ;;
            2)
                clean_aggressive
                ;;
            3)
                diagnostic
                ;;
            4)
                live_monitor
                ;;
            5)
                show_top_processes
                ;;
            6)
                dialog --title "SALIR" \
                       --yesno "¿Estás seguro de que quieres salir?" 6 40
                if [ $? -eq 0 ]; then
                    clear
                    echo -e "¡Gracias por usar el optimizador de RAM!"
                    echo -e "Memoria final:"
                    free -h
                    exit 0
                fi
                ;;
            *)
                # Si se cancela o ESC, salir
                clear
                echo -e "¡Gracias por usar el optimizador de RAM!"
                echo -e "Memoria final:"
                free -h
                exit 0
                ;;
        esac
    done
}

# Verificar que se ejecute en terminal interactiva
if [ ! -t 0 ]; then
    echo "Este script debe ejecutarse en una terminal interactiva"
    exit 1
fi

# Iniciar menú principal
main_menu
