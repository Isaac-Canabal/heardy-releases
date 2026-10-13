/// Términos de uso y política de privacidad tal como los muestra la app.
///
/// Misma versión y mismo contenido (condensado, no distinto) que la web:
/// cuando cambie el texto ahí, sube [legalVersion] aquí y en
/// `web/src/content/downloads.ts` (`termsVersion`) a la vez — la app vuelve a
/// pedir la aceptación a quien tenga registrada una versión anterior.
const String legalVersion = '2026-10-13';

const String legalOperator = 'Vainastech';
const String legalContactEmail = 'vainastech@gmail.com';

/// La primera versión de la app que pide aceptación registra qué versión se
/// aceptó y cuándo; una versión nueva de los textos la vuelve a pedir.
bool needsLegalAcceptance(String? acceptedVersion) => acceptedVersion != legalVersion;

class LegalSection {
  final String title;
  final String body;
  const LegalSection(this.title, this.body);
}

const List<LegalSection> termsSections = [
  LegalSection(
    '1. Qué es Heardy',
    'Heardy es una aplicación gratuita y de código abierto para Android y Windows que reproduce '
        'archivos de audio almacenados en tu dispositivo. Permite organizarlos en playlists, mostrar '
        'letras sincronizadas y su traducción, consultar estadísticas de escucha y, de forma opcional, '
        'mantener una cuenta para sincronizar un índice de la biblioteca entre tus dispositivos y '
        'compartir ciertos datos con las personas que aceptes como amigos.\n\n'
        'El operador de Heardy es $legalOperator, con domicilio en Colombia («el operador»).',
  ),
  LegalSection(
    '2. Heardy es un reproductor local',
    'Heardy no es un servicio de música por suscripción ni un catálogo de contenidos. Reproduce '
        'los archivos de audio que están en la carpeta de tu dispositivo que eliges, y el audio de tu '
        'biblioteca nunca se sube a ningún servidor, ni siquiera cuando usas la cuenta opcional. El '
        'operador no mantiene un catálogo de contenidos ni pone ningún contenido a disposición de '
        'otros usuarios.\n\n'
        'Cuando usas la importación desde enlaces, el servidor de extracción obtiene el archivo que '
        'pides solo para ti y lo entrega a tu dispositivo, conservando como máximo una caché técnica '
        'temporal de tamaño limitado. La función opcional de escucha en streaming resuelve la transmisión en tu propio '
        'dispositivo.',
  ),
  LegalSection(
    '3. Importación desde enlaces y contenido de terceros',
    'De forma secundaria y opcional, Heardy permite importar audio a la biblioteca local a partir '
        'de un enlace a plataformas de terceros, mediante un servidor de extracción operado por el '
        'operador o por ti. El uso de esta función es tu exclusiva responsabilidad. Al utilizarla '
        'declaras y garantizas que:\n\n'
        '• tienes derecho a obtener y conservar una copia del contenido (porque lo has adquirido, '
        'cuentas con una licencia que lo permite, es de tu autoría o está en el dominio público);\n'
        '• respetas las condiciones de uso de la plataforma de origen y la legislación aplicable en '
        'materia de derechos de autor y derechos conexos, en particular la Ley 23 de 1982 de '
        'Colombia y las normas equivalentes de tu país;\n'
        '• usas el contenido importado solo para uso personal y privado, sin fines comerciales y sin '
        'redistribuirlo ni comunicarlo públicamente.\n\n'
        'Estas funciones no están pensadas para obtener obras sin autorización, y el operador puede '
        'bloquear cualquier identificador de origen (véase la sección 9).\n\n'
        'El operador no verifica estas declaraciones. Si no puedes hacerlas, no uses estas '
        'funciones.\n\n'
        'El servidor ejecuta, a petición tuya y para ti, la descarga de un archivo concreto que tú '
        'identificas. El operador no revisa previamente cada enlace y no adquiere ningún derecho '
        'sobre el archivo. El servidor conserva el archivo solicitado en una caché de tamaño '
        'limitado, identificada únicamente por el identificador del vídeo y no vinculada a tu '
        'cuenta, hasta que se reemplaza al alcanzarse el límite o el operador la borra; no lo ofrece '
        'a otros usuarios como catálogo. El operador puede limitar, suspender o retirar esta función '
        'en cualquier momento, bloquear identificadores, enlaces o cuentas ante indicios de uso '
        'indebido, y atenderá los requerimientos legítimos de autoridades y titulares de derechos '
        'conforme a la sección 9.\n\n'
        'Heardy no está afiliado, respaldado ni patrocinado por ninguna de las plataformas de '
        'terceros cuyo contenido un usuario pueda enlazar, ni por Google ni por NewPipe.',
  ),
  LegalSection(
    '4. Uso permitido y prohibiciones',
    'Heardy se ofrece para uso personal y no comercial. Queda prohibido: usarlo con fines comerciales '
        'o para redistribuir contenido; revender o sublicenciar el acceso a los servicios de la cuenta; '
        'intentar eludir límites técnicos, cuotas o mecanismos de autenticación del servidor opcional, '
        'o sobrecargarlo; usar la función de amigos o de nombre de usuario para acosar, suplantar o '
        'localizar a otras personas, o elegir nombres ofensivos o que induzcan a confusión; y usar '
        'Heardy para infringir derechos de terceros o la ley.\n\n'
        'El código fuente de Heardy se publica bajo la licencia GPL-3.0. Esa licencia regula el uso del '
        'código; estos términos regulan el uso de la aplicación compilada distribuida por el operador '
        'y de los servicios asociados. Las prohibiciones de esta sección se aplican al uso de los '
        'servicios del operador (servidor, cuenta) y de la aplicación compilada que él distribuye, y '
        'no limitan los derechos que te concede la GPL-3.0 sobre el código fuente.',
  ),
  LegalSection(
    '5. Cuenta opcional',
    'Todas las funciones esenciales (biblioteca, reproducción, playlists, letras, estadísticas) '
        'funcionan sin cuenta y sin conexión. Crear una cuenta es opcional y permite sincronizar entre '
        'tus dispositivos un índice de tu biblioteca (títulos, artistas, duración, playlists y el '
        'enlace de origen de una canción cuando exista), tu historial de reproducción y tus '
        'estadísticas; elegir un nombre de usuario; enviar y aceptar solicitudes de amistad; y, si lo '
        'activas expresamente, compartir con tus amigos la canción que escuchas.\n\n'
        'La cuenta se gestiona a través de un proveedor de identidad externo; el operador nunca ve ni '
        'almacena tu contraseña. Es necesario verificar el correo para usar los servicios con cuenta. '
        'Puedes borrar todos los datos asociados a tu cuenta desde Ajustes («Borrar mis datos de la '
        'nube»).',
  ),
  LegalSection(
    '6. Edad mínima',
    'Para usar Heardy debes tener al menos 14 años. Para crear la cuenta opcional debes ser mayor de '
        'edad conforme a la ley de tu país; los mayores de 14 y menores de edad solo pueden crearla con '
        'la autorización de sus padres o tutores, quienes responden de ese uso.\n\n'
        'Si eres menor de edad, las secciones 8 (indemnidad) y 11 (resolución de controversias) no se '
        'aplican a tu cuenta como se aplican a los adultos: la indemnidad no te es aplicable y '
        'quienes responden por la cuenta son tus representantes legales, que conservan en todo '
        'momento el derecho de acudir a la Superintendencia de Industria y Comercio o a la '
        'jurisdicción competente.',
  ),
  LegalSection(
    '7. Sin garantías y limitación de responsabilidad',
    'Heardy se proporciona «tal cual» y «según disponibilidad», sin garantías de ningún tipo. El '
        'operador no garantiza compatibilidad con todos los dispositivos ni disponibilidad continua de '
        'los servicios opcionales, que pueden tener cuotas, interrupciones o dejar de prestarse. En la '
        'máxima medida permitida por la ley, el operador no responde de daños indirectos ni de pérdida '
        'de datos o archivos; te recomendamos mantener copias de seguridad de tu música. Nada limita '
        'los derechos irrenunciables que te reconozca la legislación de protección al consumidor.',
  ),
  LegalSection(
    '8. Responsabilidad del usuario por el contenido e indemnidad',
    'Todo el contenido que reproduces, importas, almacenas o sincronizas con Heardy es tuyo o lo '
        'obtienes tú: el operador no lo revisa previamente ni lo pone a disposición de otros usuarios. '
        'Eres el único responsable de que ese contenido y el uso que hagas de él respeten los '
        'derechos de terceros (en particular los derechos de autor y conexos), las condiciones de las '
        'plataformas de origen y la ley. Si importas o conservas contenido sin tener derecho a ello, '
        'la responsabilidad es exclusivamente tuya.\n\n'
        'Si tu uso infractor genera una reclamación contra el operador, te comprometes a reembolsarle '
        'los daños y costos razonables y documentados que se deriven directamente de ello, salvo que '
        'hayan sido causados por dolo o culpa grave del operador. Esta cláusula no aplica a menores de '
        'edad ni limita derechos irrenunciables del consumidor. El operador podrá cooperar con '
        'autoridades y titulares de derechos en la medida que la ley exija.',
  ),
  LegalSection(
    '9. Derechos de autor, uso aceptable y retiro de contenido',
    'Respeto de la propiedad intelectual\n'
        'Heardy respeta los derechos de autor y espera lo mismo de quienes lo usan. No uses la '
        'importación desde enlaces ni el streaming para obras sobre las que no tengas derecho, ni para '
        'redistribuirlas. El procedimiento descrito en esta sección es un compromiso voluntario del '
        'operador.\n\n'
        'Qué se puede notificar\n'
        '• Un identificador de origen (por ejemplo, el identificador de un vídeo) que el servidor de '
        'extracción debería dejar de servir.\n'
        '• Un dato del índice sincronizado de un usuario (por ejemplo, un enlace de origen o un nombre '
        'de usuario).\n'
        '• La conducta de una cuenta.\n'
        'El streaming se resuelve en tu dispositivo y no pasa por el servidor del operador; el operador '
        'puede desactivar esa función en futuras versiones y atenderá las reclamaciones sobre ella '
        'remitiéndolas, si procede, a la plataforma de origen. Los archivos que ya están en un '
        'dispositivo quedan fuera del control del operador.\n\n'
        'Qué debe contener la notificación\n'
        '• Identificación y datos de contacto de quien reclama (y prueba de su representación, si '
        'actúa en nombre de otro).\n'
        '• Identificación de la obra afectada.\n'
        '• Identificación del identificador de origen, la URL o el dato señalado.\n'
        '• Declaración de buena fe de que el uso no está autorizado por el titular, su representante '
        'o la ley.\n'
        '• Declaración de que la información es exacta y, bajo la responsabilidad de quien reclama, de '
        'que es el titular de los derechos o está autorizado para actuar en su nombre.\n'
        '• Firma (basta el nombre escrito).\n'
        'Envíala a $legalContactEmail.\n\n'
        'Plazos\n'
        'El operador acusará recibo en un máximo de tres (3) días hábiles. Si la notificación está '
        'completa y es fundada, bloqueará el identificador en el servidor de extracción en un máximo de '
        'cinco (5) días hábiles desde que la reciba completa. Si está incompleta, pedirá los datos que '
        'falten.\n\n'
        'Contranotificación\n'
        'Cuando la cuenta afectada sea identificable, el operador informará al usuario, que podrá '
        'responder con la misma información y una declaración de buena fe. El bloqueo se mantiene salvo '
        'que la respuesta demuestre que el uso es lícito o que quien reclamó retire su reclamación.\n\n'
        'Reincidentes\n'
        'Tras tres (3) notificaciones fundadas contra contenido vinculado a una misma cuenta, el '
        'operador suspenderá su acceso a los servicios opcionales.\n\n'
        'Notificaciones abusivas o falsas\n'
        'Las notificaciones abusivas o falsas podrán desestimarse, y quien reclame a sabiendas de forma '
        'falsa responde por los daños que cause.\n\n'
        'Autoridades competentes\n'
        'El operador atenderá los requerimientos de las autoridades competentes. Nada de esta sección '
        'limita el derecho de los titulares a acudir a los jueces o a las autoridades competentes.',
  ),
  LegalSection(
    '10. Suspensión y terminación',
    'Puedes dejar de usar Heardy en cualquier momento desinstalándolo y, si tienes cuenta, borrando '
        'tus datos desde Ajustes. El operador puede suspender el acceso a los servicios opcionales de '
        'quien incumpla estos términos, o descontinuarlos con un preaviso razonable cuando sea posible. '
        'La aplicación seguirá funcionando en modo local aunque los servicios opcionales dejen de '
        'prestarse.',
  ),
  LegalSection(
    '11. Ley aplicable y resolución de controversias',
    'Estos términos se rigen por las leyes de la República de Colombia. Antes de iniciar un '
        'procedimiento, las partes intentarán resolver la controversia de forma directa, por escrito '
        '(tú a $legalContactEmail; el operador al correo de tu cuenta), durante treinta (30) días. Esta '
        'etapa no limita tu derecho a acudir en cualquier momento a la Superintendencia de Industria y '
        'Comercio, a un juez o a una autoridad de protección de datos.\n\n'
        'Los usuarios consumidores conservan todos los derechos que la legislación imperativa que los '
        'proteja les reconozca.',
  ),
  LegalSection(
    '12. Uso de inteligencia artificial en el desarrollo',
    'Heardy se desarrolla con asistencia de herramientas de inteligencia artificial para escribir y '
        'revisar código, textos y documentación, siempre bajo supervisión humana. Ningún dato personal '
        'de los usuarios ni el contenido de sus bibliotecas se utiliza para entrenar modelos ni se '
        'comparte con proveedores de inteligencia artificial.',
  ),
  LegalSection(
    '13. Cambios y aceptación',
    'La versión vigente, con su fecha, está siempre publicada en la web del proyecto y en esta '
        'pantalla. Si el cambio es sustancial, la aplicación te pedirá aceptarlo de nuevo y se '
        'registrará la nueva versión aceptada y la fecha. Aceptas '
        'estos términos al pulsar «Aceptar y continuar» la primera vez que abres la app (se registra la '
        'versión aceptada y la fecha). Si no estás de acuerdo, no uses Heardy.',
  ),
];

const List<LegalSection> privacySections = [
  LegalSection(
    '1. Responsable',
    '$legalOperator, Colombia. Contacto para asuntos de privacidad: $legalContactEmail.',
  ),
  LegalSection(
    '2. Uso sin cuenta: tu biblioteca no sale de tu dispositivo',
    'Si usas Heardy sin crear una cuenta, toda la información (tu biblioteca, playlists, historial '
        'de reproducción, estadísticas, ajustes) se guarda únicamente en tu dispositivo y el operador '
        'no recibe ninguno de esos datos. La aplicación sí hace algunas conexiones a internet en este '
        'modo: consulta a GitHub si hay una versión nueva (lo que expone tu dirección IP a GitHub; en '
        'Windows también actualiza desde GitHub su componente yt-dlp empaquetado); busca letras en '
        'LRCLIB y, como fuente alternativa, en NetEase Cloud Music, enviando el título y el artista de '
        'la canción (y su duración a LRCLIB); si pides una traducción, envía el texto de cada línea de '
        'la letra al servicio MyMemory; y si usas «Escuchar» (streaming), se conecta directamente desde '
        'tu dispositivo a la plataforma de origen del contenido. Ninguna de estas conexiones envía tu '
        'biblioteca ni un identificador de cuenta. Importar desde enlaces, la búsqueda en línea y '
        'Explorar requieren una cuenta (véase la sección 3).',
  ),
  LegalSection(
    '3. Qué tratamos si creas una cuenta',
    '• Correo electrónico y estado de verificación, gestionados por el proveedor de identidad; nunca '
        'tu contraseña.\n'
        '• Índice de tu biblioteca: títulos, artistas, álbum, duración, una huella del audio que no '
        'permite reconstruirlo, playlists y el enlace de origen cuando una canción se importó desde un '
        'enlace. Nunca rutas de archivos ni el audio de tu biblioteca.\n'
        '• Historial de reproducción: qué canción, cuándo y durante cuánto tiempo.\n'
        '• Nombre de usuario y relaciones de amistad.\n'
        '• «Escuchando ahora», solo si lo activas: visible solo para tus amigos y caduca al terminar la '
        'canción. Está desactivado por defecto.\n'
        '• Uso de Explorar, importar y buscar: las búsquedas que haces, los enlaces que importas, el '
        'país que eliges en Explorar y los identificadores de vídeo de tus canciones más escuchadas '
        'que tienen enlace de origen (para generar recomendaciones). Se procesan en el servidor para '
        'atender cada solicitud.\n'
        '• Datos técnicos mínimos para operar el servicio (cuotas por cuenta, marcas de sincronización, '
        'registros que nunca combinan tu identidad con el contenido de tus datos).',
  ),
  LegalSection(
    'Resumen de lo que se recoge',
    'Sin cuenta, el operador no recibe nada (la aplicación solo contacta con terceros para '
        'versiones, letras, traducciones y streaming, como se explica en la sección 2). Con cuenta: '
        'tu correo (a través del proveedor de identidad), el índice de tu biblioteca, tu historial de '
        'reproducción, tu nombre de usuario, tus amistades, «escuchando ahora» si lo activas, lo que '
        'buscas, importas o pides a Explorar, y los contadores técnicos de uso. Nunca el audio de tu '
        'biblioteca, nunca rutas de archivos, nunca analítica ni publicidad.',
  ),
  LegalSection(
    '4. Qué no recogemos',
    'El audio de tu biblioteca (nunca se sube); rutas o nombres de carpetas; analítica, seguimiento o publicidad (no hay '
        'ningún SDK de ese tipo); contactos, ubicación ni micrófono; datos de pago.',
  ),
  LegalSection(
    '5. Finalidad y base legal',
    'Los datos de la cuenta se usan exclusivamente para las funciones que activas (sincronizar y '
        'restaurar tu índice e historial, nombre de usuario, amigos, «escuchando ahora») y, de forma '
        'agregada, para la seguridad y los límites de uso. La base legal es tu autorización previa, '
        'expresa e informada (artículo 9 de la Ley 1581 de 2012) que otorgas al vincular la cuenta; '
        'para usuarios de la Unión Europea, el consentimiento y la ejecución del servicio (artículo 6.1 '
        'a y b del RGPD). Puedes retirarla en cualquier momento borrando tus datos.',
  ),
  LegalSection(
    '6. Dónde se procesan',
    'El servidor opcional y la base de datos corren en proveedores externos que actúan como '
        'encargados (Google Firebase para la identidad; Render y Neon para el servidor y la base de '
        'datos) y alojan los datos en Estados Unidos. Esa transferencia internacional se ampara en tu '
        'autorización expresa (artículo 26 de la Ley 1581 de 2012 y Circular 005 de 2017 de la SIC) y '
        'en los acuerdos de tratamiento de datos de dichos proveedores. No cedemos ni vendemos tus '
        'datos a nadie más.',
  ),
  LegalSection(
    '7. Qué ven otros usuarios',
    'Quien no sea tu amigo solo puede comprobar si un nombre de usuario exacto existe; nunca ve tu '
        'correo, el tamaño de tu biblioteca ni tus estadísticas. Tus amigos ven tu nombre de usuario, '
        'tus estadísticas de escucha y, solo si lo activaste, la canción que estás escuchando. Puedes '
        'retirar una amistad cuando quieras.',
  ),
  LegalSection(
    '8. Conservación',
    'Los datos de la cuenta se conservan mientras exista. «Escuchando ahora» caduca solo. Los '
        'registros técnicos se conservan como máximo 30 días. Al borrar tus datos se eliminan de '
        'inmediato de la base de datos; las copias de seguridad automáticas se purgan en un máximo de '
        '30 días adicionales. Si el servicio opcional dejara de prestarse, los datos de todas las '
        'cuentas se eliminarían en ese mismo plazo.',
  ),
  LegalSection(
    '9. Tus derechos',
    'Conforme a la Ley 1581 de 2012 y el Decreto 1377 de 2013 puedes conocer, actualizar y rectificar '
        'tus datos, pedir prueba de la autorización, revocarla y solicitar la supresión, y presentar '
        'quejas ante la Superintendencia de Industria y Comercio. En la Unión Europea tienes además los '
        'derechos del RGPD. La forma más rápida de suprimir tus datos es Ajustes → Cuenta → «Borrar mis '
        'datos de la nube». Para cualquier otra solicitud escribe a $legalContactEmail desde el correo '
        'de tu cuenta; respondemos en los plazos legales.',
  ),
  LegalSection(
    'Inteligencia artificial',
    'Heardy se desarrolla con asistencia de herramientas de inteligencia artificial, bajo supervisión '
        'humana. Esas herramientas no tienen acceso a los datos de los usuarios: ningún dato personal ni '
        'contenido de tu biblioteca se usa para entrenar modelos ni se envía a proveedores de '
        'inteligencia artificial. La aplicación no toma decisiones automatizadas con efectos jurídicos '
        'sobre ti.',
  ),
  LegalSection(
    '10. Seguridad y menores',
    'La comunicación con el servidor va cifrada; el acceso exige un token de sesión que caduca; el '
        'servidor no guarda contraseñas. Al importar desde un enlace, el servidor descarga el archivo '
        'que pides para entregártelo y lo conserva en una caché técnica de tamaño limitado, '
        'identificada únicamente por el identificador del vídeo y no vinculada a tu cuenta, hasta que '
        'se reemplaza al alcanzarse el límite o el operador la borra; no se ofrece a otros usuarios '
        'como catálogo. Heardy no está dirigido a menores de 14 años; la '
        'cuenta opcional es para mayores de edad, o para mayores de 14 con autorización de sus padres o '
        'tutores (artículo 7 de la Ley 1581 de 2012). Si crees que un menor facilitó datos sin esa '
        'autorización, escríbenos y los eliminaremos.',
  ),
];
