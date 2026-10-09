/// Términos de uso y política de privacidad tal como los muestra la app.
///
/// Misma versión y mismo contenido (condensado, no distinto) que la web:
/// cuando cambie el texto ahí, sube [legalVersion] aquí y en
/// `web/src/content/downloads.ts` (`termsVersion`) a la vez — la app vuelve a
/// pedir la aceptación a quien tenga registrada una versión anterior.
const String legalVersion = '2026-09-19';

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
        'únicamente archivos que ya están en el almacenamiento de tu dispositivo, en la carpeta que '
        'eliges. El operador no aloja, almacena, transmite ni distribuye ningún archivo de audio: el '
        'audio nunca sale de tu dispositivo, ni siquiera cuando usas la cuenta opcional.',
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
        'materia de derechos de autor y derechos conexos, en particular la Ley 23 de 1982 y la Ley '
        '1915 de 2018 de Colombia y las normas equivalentes de tu país;\n'
        '• usas el contenido importado solo para uso personal y privado, sin fines comerciales y sin '
        'redistribuirlo ni comunicarlo públicamente.\n\n'
        'El servidor actúa como una herramienta técnica que ejecuta, a petición expresa tuya y para '
        'ti, la obtención de un archivo concreto; el operador no selecciona, controla ni aprueba los '
        'enlaces que introduces, no conserva el audio más allá de una caché técnica temporal, no lo '
        'pone a disposición de otros usuarios y no adquiere ningún derecho sobre él. El operador puede '
        'limitar, suspender o retirar esta función en cualquier momento, bloquear enlaces o cuentas '
        'ante indicios de uso indebido, y atenderá los requerimientos legítimos de autoridades y '
        'titulares de derechos.',
  ),
  LegalSection(
    '4. Uso permitido y prohibiciones',
    'Heardy se ofrece para uso personal y no comercial. Queda prohibido: usarlo con fines comerciales '
        'o para redistribuir contenido; revender o sublicenciar el acceso a los servicios de la cuenta; '
        'intentar eludir límites técnicos, cuotas o mecanismos de autenticación del servidor opcional, '
        'o sobrecargarlo; usar la función de amigos o de nombre de usuario para acosar, suplantar o '
        'localizar a otras personas, o elegir nombres ofensivos o que induzcan a confusión; y usar '
        'Heardy para infringir derechos de terceros o la ley.\n\n'
        'El código fuente se publica bajo la licencia MIT. Esa licencia regula el uso del código; estos '
        'términos regulan el uso de la aplicación compilada y de los servicios asociados.',
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
        'la autorización de sus padres o tutores, quienes responden de ese uso.',
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
        'obtienes tú: el operador no lo elige, no lo revisa y no lo aloja. Eres el único responsable de '
        'que ese contenido y el uso que hagas de él respeten los derechos de terceros (en particular '
        'los derechos de autor y conexos), las condiciones de las plataformas de origen y la ley. Si '
        'importas o conservas contenido sin tener derecho a ello, la responsabilidad es exclusivamente '
        'tuya.\n\n'
        'Te comprometes a mantener indemne al operador, a sus colaboradores y proveedores frente a '
        'cualquier reclamación, sanción, daño o gasto (incluidos honorarios legales razonables) derivado '
        'del contenido que hayas reproducido, importado, almacenado o compartido a través de Heardy, de '
        'tu incumplimiento de estos términos o de tu infracción de derechos de terceros o de la ley. El '
        'operador podrá cooperar con autoridades y titulares de derechos en la medida que la ley exija.',
  ),
  LegalSection(
    '9. Reclamaciones de derechos de autor',
    'Si consideras que un enlace de origen almacenado en el índice de un usuario, un nombre de '
        'usuario u otro dato gestionado por el operador infringe tus derechos, escribe a '
        '$legalContactEmail con tu identificación, la obra afectada, el dato señalado y una declaración '
        'de buena fe. El operador acusará recibo y responderá en un máximo de quince días hábiles; si la '
        'reclamación es fundada retirará el dato e informará al usuario afectado, que podrá responder. '
        'Las reclamaciones abusivas podrán desestimarse y las cuentas reincidentes suspenderse.',
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
    'Estos términos se rigen por las leyes de la República de Colombia. Antes de iniciar cualquier '
        'acción, las partes intentarán resolver la controversia de forma directa, por escrito (tú a '
        '$legalContactEmail; el operador al correo de tu cuenta), durante treinta (30) días.\n\n'
        'Si no hay acuerdo, toda controversia derivada de estos términos o del uso de Heardy se '
        'resolverá mediante arbitraje en derecho conforme a la Ley 1563 de 2012, ante el Centro de '
        'Arbitraje y Conciliación de la Cámara de Comercio de Bogotá, por un árbitro único, con sede en '
        'Bogotá y en español. El laudo será definitivo y vinculante; cada parte asume sus costos salvo '
        'que el laudo disponga otra cosa.\n\n'
        'Cuando actúes como consumidor y la ley que te proteja te reconozca el derecho a acudir a la '
        'jurisdicción ordinaria o a la autoridad de protección al consumidor (en Colombia, la '
        'Superintendencia de Industria y Comercio), este arbitraje es opcional para ti y no limita ese '
        'derecho. En la medida permitida por la ley, las controversias se resuelven de forma '
        'individual, no mediante acciones colectivas o de grupo.',
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
        'pantalla. Si el cambio es sustancial, la aplicación te pedirá aceptarlo de nuevo. Aceptas '
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
    '2. Sin cuenta, nada sale de tu dispositivo',
    'Si usas Heardy sin cuenta, toda tu información (biblioteca, playlists, historial, estadísticas, '
        'ajustes) se guarda solo en tu dispositivo y el operador no recibe ningún dato. Las únicas '
        'conexiones son las necesarias para obtener letras y traducciones, enviando el título, el '
        'artista y la duración de la canción a servicios de terceros, sin ningún identificador tuyo.',
  ),
  LegalSection(
    '3. Qué tratamos si creas una cuenta',
    '• Correo electrónico y estado de verificación, gestionados por el proveedor de identidad; nunca '
        'tu contraseña.\n'
        '• Índice de tu biblioteca: títulos, artistas, álbum, duración, una huella del audio que no '
        'permite reconstruirlo, playlists y el enlace de origen cuando una canción se importó desde un '
        'enlace. Nunca rutas de archivos ni el audio.\n'
        '• Historial de reproducción: qué canción, cuándo y durante cuánto tiempo.\n'
        '• Nombre de usuario y relaciones de amistad.\n'
        '• «Escuchando ahora», solo si lo activas: visible solo para tus amigos y caduca al terminar la '
        'canción. Está desactivado por defecto.\n'
        '• Datos técnicos mínimos para operar el servicio (cuotas por cuenta, marcas de sincronización, '
        'registros que nunca combinan tu identidad con el contenido de tus datos).',
  ),
  LegalSection(
    'Resumen de lo que se recoge',
    'Sin cuenta, nada (salvo título, artista y duración de la canción para pedir letras). Con cuenta: '
        'tu correo (a través del proveedor de identidad), el índice de tu biblioteca, tu historial de '
        'reproducción, tu nombre de usuario, tus amistades, «escuchando ahora» si lo activas, y los '
        'contadores técnicos de uso. Nunca el audio, nunca rutas de archivos, nunca analítica ni '
        'publicidad.',
  ),
  LegalSection(
    '4. Qué no recogemos',
    'Tus archivos de audio; rutas o nombres de carpetas; analítica, seguimiento o publicidad (no hay '
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
        '30 días adicionales.',
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
        'servidor no almacena contraseñas ni audio. Heardy no está dirigido a menores de 14 años; la '
        'cuenta opcional es para mayores de edad, o para mayores de 14 con autorización de sus padres o '
        'tutores (artículo 7 de la Ley 1581 de 2012). Si crees que un menor facilitó datos sin esa '
        'autorización, escríbenos y los eliminaremos.',
  ),
];
