#!/home/explorer/perl5/perlbrew/perls/perl-5.28.0/bin/perl -s
#
# actualizar_hoja_estadisticas.pl
#
# · Actualiza las estadísticas en Google Doc
#
# Uso:
# -l : Lista los archivos
#
# Joaquín Ferrero. 20210517
# Última versión:  20210603
#
use v5.28.0;
use utf8;
use locale;						# localización de la ordenación de cadenas; formateo de números
use autodie;
use open IO => qw':std :locale';			# E/S según localización regional

use Try::Tiny;
use Path::Tiny;						# operaciones con archivos
use Google::RestApi;
use Google::RestApi::SheetsApi4;

#use Data::Printer array_max => 5;
#use Data::Dumper;


## Configuración ------------------------------------------------------------------------------------------------------
my $PERL_VERSION = 'v5.24.0';						# versión Perl de trabajo
my $USER	 = 'explorer';						# archivo TMX con la memoria de trabajo del usuario

my $DIR_ROOT	 = path("/home/$USER/Proyectos/perldocES/v5");		# ruta al directorio principal
my $PROJECT	 = 'work.github';					# directorio de trabajo
my $DIR_PROJECT	 = $DIR_ROOT->child($PROJECT);				# ruta al directorio de trabajo
my $CREDENCIALES = $DIR_ROOT->child('tools/credenciales.yml');		# ruta al archivo con las credenciales

my $FILE_LIST	 = $DIR_PROJECT->child("files.lst");			# ruta al archivo con las descripciones
my $FILE_STATS	 = $DIR_PROJECT->child("omegat/project_stats.txt");	# ruta al archivo con las estadísticas

my $GOOGLE_LIBRO = 'PerlDoc-ES.Traducción';				# nombre del libro
my $GOOGLE_HOJA	 = $PERL_VERSION;					# nombre de la hoja
## Fin de configuración -----------------------------------------------------------------------------------------------


## Comprobaciones -----------------------------------------------------------------------------------------------------
$FILE_LIST->exists  or die "ERROR: No encuentro el listado de archivos [$FILE_LIST]\n";
$FILE_STATS->exists or die "ERROR: No encuentro el archivo de estadísticas [$FILE_STATS]\n";


## Leer el archivo de descripciones -----------------------------------------------------------------------------------
# clave: nombre del archivo
# valor: descripción del archivo
say "Leer archivo de descripciones...";
my %pod_descripción_de = map { split " ", $_, 2; } $FILE_LIST->lines({ chomp => 1 });


## Leer el archivo de estadísticas ------------------------------------------------------------------------------------
# clave: nombre del archivo
# valor: estadísticas de traducción del archivo: [  [ ]  ]
say "Leer archivo de estadísticas...";
my %estadísticas;
for ( $FILE_STATS->lines ) {
    my @campos = split;
    next if @campos != 17;
    $estadísticas{ $campos[0] } = [ @campos[ 0 .. 8 ] ];
}


# Mostrar la lista de ficheros ----------------------------------------------------------------------------------------
our $l;							# Opción al programa: lista los ficheros junto con sus descripciones
if ($l) {
    my $fila = 2;						# número de fila en la hoja
    for my $fichero (sort { lc($a) cmp lc($b) } keys %estadísticas) {
	say "$fila $fichero\t$pod_descripción_de{$fichero}";
	$fila++;
    }

    exit;
}


## Acceso a la hoja en Google -----------------------------------------------------------------------------------------
say "Acceso a la hoja...";
my $google_hojas = Google::RestApi::SheetsApi4->new(
    api => Google::RestApi->new(
	config_file => "$CREDENCIALES",
    )
);

my $libro = $google_hojas->open_spreadsheet(name => $GOOGLE_LIBRO);
my $hoja  = $libro->open_worksheet(name => $GOOGLE_HOJA);

my $gridProperties_ref = $hoja->properties('gridProperties');
$gridProperties_ref    = $gridProperties_ref->{'gridProperties'};
my $número_filas       = $gridProperties_ref->{'rowCount'};


## Titulares de las columnas que nos interesan ------------------------------------------------------------------------
# Estos índices corresponden a los de la hoja de cálculo
# archivo|descripcion|traductor|revisor|version|seg.|seg. pend.|%seg|unicos|unic. pend.|%unico|palabras|pal. pend.|%pal|unicas|unicas pend.|%unica|%interes
# 1       2           3         4	5	6    7		8    9	    10		11     12	13	   14	15     16	    17	   18

# Los titulares están puestos en el orden en que aparecen en %estadísticas
my @titulares        = ('archivo',  'seg.', 'seg. pend.', 'unicos', 'unic. pend.', 'palabras', 'pal. pend.', 'unicas', 'unicas pend.');

# Hace falta una traducción de número de columna entre las de %estadísticas y las de la hoja de cálculo
my @índices_columnas = ( 1,          6,      7,            9,        10,            12,         13,           15,       16           );
#my %titulares_a_índicescolumnas = map { $titulares[$_] => $índices_columnas[$_] } 0..$#titulares;


## Actualizar la hoja -------------------------------------------------------------------------------------------------
say "Leer la hoja...";
my $rango_cambios = $libro->range_group();			# registro de cambios en toda la hoja
my $columnas_ref  = $hoja->tie_cols(@titulares);		# Leer todas las celdas de la hoja

# Recorremos los datos por filas
for my $num_fila (1 .. $número_filas) {								# FILA, 1 .. filas
    my($archivo) = $columnas_ref->{archivo}[$num_fila];

    if (exists $estadísticas{$archivo}) {

	# comprobar si hubo cambios entre las %estadísticas y lo que contiene las $columnas_ref en esta $num_fila
	# $num_columna está basada en '0', para recorrer @titulares, y coincide con las columnas de %estadísticas

	while(my($num_columna, $columna) = each @titulares) {					# COLUMNA, 0 .. columnas

	    if ($columnas_ref->{$columna}[$num_fila] ne $estadísticas{$archivo}[$num_columna]) {

		# Si es distinto, creamos un rango de una celda y le damos el nuevo valor, pero en batch,
		# para aplicar todos los cambios de golpe
#		my $celda_cambiada = $hoja->range_cell([$titulares_a_índicescolumnas{$columna}, $num_fila+1]);
		my $celda_cambiada = $hoja->range_cell([$índices_columnas[$num_columna], $num_fila+1]);
		$celda_cambiada->batch_values(values => $estadísticas{$archivo}[$num_columna]);
		$rango_cambios->append($celda_cambiada);
	    }
	}
    }
}

# actualizamos si hay cambios
if (my @cambios = $rango_cambios->ranges()) {
    say "Hubo cambios, actualizando hoja...";
    $rango_cambios->submit_values();
}
else {
    say "No hay cambios";
}

__END__
