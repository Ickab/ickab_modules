# ICKAB — Política de versiones y publicaciones

## 1. Objetivo

Establecer las reglas para incorporar, versionar y distribuir los módulos oficiales de ICKAB para Odoo.

El repositorio `ickab_modules` contiene exclusivamente módulos terminados, probados y autorizados para distribución.

## 2. Organización del repositorio

Los módulos se organizan por versión principal de Odoo:

- `17.0/`
- `18.0/`
- `19.0/`

Cada módulo conserva su nombre técnico y su propio ciclo de versiones.

No se asumirá compatibilidad entre distintas versiones de Odoo sin validación.

## 3. Desarrollo y publicación comercial

El desarrollo se realiza fuera del repositorio de distribución.

Las revisiones realizadas por Codex, Claude Code u otros desarrolladores se identifican mediante el historial de Git del proyecto de desarrollo.

Las revisiones internas no representan automáticamente versiones comerciales.

La primera publicación comercial de un módulo podrá identificarse como `1.0.0`, siempre que se haya validado su instalación y su historial técnico de versiones.

## 4. Convención de versiones

Se utilizará la siguiente estructura en el manifiesto de Odoo:

`VERSION_ODOO.MAYOR.MENOR.CORRECCIÓN`

Ejemplos:

- `18.0.1.0.0`: primera versión comercial para Odoo 18.
- `18.0.1.0.1`: corrección compatible.
- `18.0.1.1.0`: mejora funcional compatible.
- `18.0.2.0.0`: cambio mayor.

Los incrementos de versión deben documentarse y ser coherentes con las instalaciones existentes.

## 5. Identificación de publicaciones

Cada publicación tendrá una etiqueta única de Git.

Formato:

`nombre_modulo-vVERSION`

Ejemplos:

- `ick_direct_print-v18.0.1.0.0`
- `ick_direct_print-v19.0.1.0.0`
- `ick_label_studio-v18.0.1.0.0`

No se reutilizarán ni modificarán etiquetas de versiones comerciales ya publicadas.

## 6. GitHub Releases

Cada Release deberá incluir:

- Nombre técnico del módulo.
- Versión de Odoo compatible.
- Versión del módulo.
- Descripción de cambios.
- Dependencias necesarias.
- Archivo ZIP instalable.
- Archivo de verificación SHA-256.
- Instrucciones de instalación o actualización cuando correspondan.

Cada módulo se distribuirá de forma independiente, salvo que se autorice expresamente un paquete que incluya dependencias adicionales.

## 7. Clasificación de actualizaciones

### Actualización crítica

Corrige problemas graves de funcionamiento, seguridad o cumplimiento normativo.

Se pondrá a disposición de todos los compradores autorizados del módulo afectado, para las versiones de Odoo que ICKAB mantenga y que requieran la corrección.

### Actualización general

Incorpora mejoras funcionales o de rendimiento.

Su distribución dependerá de los derechos de actualización contratados por cada cliente.

### Desarrollo exclusivo

Corresponde a una modificación particular contratada por un cliente.

No se incorporará al paquete comercial general sin la autorización contractual correspondiente.

## 8. Validaciones obligatorias

Antes de publicar un módulo se deberá verificar:

1. Integridad del código.
2. Manifiesto y dependencias.
3. Compatibilidad con la versión de Odoo.
4. Instalación en una base de pruebas limpia.
5. Actualización desde versiones anteriores, cuando corresponda.
6. Ausencia de credenciales y datos confidenciales.
7. Generación correcta del ZIP.
8. Autorización de publicación por ICKAB.

## 9. Seguridad y distribución

El repositorio permanecerá privado.

Los clientes no tendrán acceso directo al código fuente completo del repositorio.

Los archivos se entregarán mediante mecanismos autorizados de distribución.

No se compartirán credenciales ni tokens de acceso a GitHub con los clientes.

## 10. Autorización

Toda publicación comercial deberá contar con aprobación de ICKAB.

Los agentes de desarrollo podrán preparar versiones y paquetes, pero no publicarlos sin autorización expresa.

---

ICKAB

*Imaginamos contigo. Crecemos juntos.*
