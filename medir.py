"""Mide cuánto tarda la cafetería en terminar una ráfaga de pedidos.

Uso (desde infra/, en Cloud Shell):
    python3 ../medir.py $(terraform output -raw url_backend) 60

Qué hace:
  1. Repone el inventario, para que todas las mediciones arranquen igual.
  2. Lanza N pedidos de un tinto, 20 a la vez, y guarda sus identificadores.
  3. Consulta cada pedido cada segundo hasta que todos estén en listo o rechazado.
  4. Imprime cuánto tardó el backend en aceptarlos y cuánto tardó el último en terminar.

Solo usa la biblioteca estándar de Python: no hay que instalar nada.
"""
import json
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

FINALES = {"listo", "rechazado"}
PLAZO_MAXIMO = 600  # segundos; si pasa esto, se rinde y dice cuántos quedaron pendientes


def pedir(url, metodo="GET", cuerpo=None):
    datos = json.dumps(cuerpo).encode() if cuerpo is not None else None
    peticion = urllib.request.Request(url, data=datos, method=metodo,
                                      headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(peticion, timeout=30) as respuesta:
        return respuesta.status, json.loads(respuesta.read() or "null")


def fecha(texto):
    return datetime.fromisoformat(texto)


def main():
    if len(sys.argv) < 2:
        sys.exit("Uso: python3 medir.py <url_backend> [cantidad_de_pedidos]")
    backend = sys.argv[1].rstrip("/")
    cantidad = int(sys.argv[2]) if len(sys.argv) > 2 else 60

    pedir(f"{backend}/inventario/reiniciar", "POST")
    print(f"Inventario repuesto. Lanzando {cantidad} pedidos...")

    def crear(i):
        _, pedido = pedir(f"{backend}/pedidos", "POST",
                          {"cliente": f"Medición {i}", "items": [{"producto": "tinto", "cantidad": 1}]})
        return pedido["id"]

    inicio = time.monotonic()
    with ThreadPoolExecutor(max_workers=20) as hilos:
        ids = list(hilos.map(crear, range(1, cantidad + 1)))
    aceptados = time.monotonic() - inicio
    print(f"El backend aceptó los {len(ids)} pedidos en {aceptados:.1f} s")

    pendientes = set(ids)
    terminados = {}
    with ThreadPoolExecutor(max_workers=20) as hilos:
        while pendientes and time.monotonic() - inicio < PLAZO_MAXIMO:
            time.sleep(1)
            lista = list(pendientes)
            for pedido_id, (_, pedido) in zip(lista, hilos.map(lambda p: pedir(f"{backend}/pedidos/{p}"), lista)):
                if pedido["estado"] in FINALES:
                    terminados[pedido_id] = pedido
                    pendientes.discard(pedido_id)
            print(f"  {time.monotonic() - inicio:5.0f} s: faltan {len(pendientes)}", end="\r")
    total_cliente = time.monotonic() - inicio
    print()

    listos = sum(1 for p in terminados.values() if p["estado"] == "listo")
    rechazados = len(terminados) - listos
    print(f"Listos: {listos}   Rechazados: {rechazados}   Sin terminar: {len(pendientes)}")

    if terminados:
        # Con las horas que guarda Firestore: del primer pedido creado al último actualizado.
        primero = min(fecha(p["creado"]) for p in terminados.values())
        ultimo = max(fecha(p["actualizado"]) for p in terminados.values())
        print(f"Tiempo hasta que el último quedó terminado (horas de Firestore): {(ultimo - primero).total_seconds():.1f} s")
    print(f"Tiempo visto desde Cloud Shell (con consultas cada 1 s): {total_cliente:.1f} s")


if __name__ == "__main__":
    main()
