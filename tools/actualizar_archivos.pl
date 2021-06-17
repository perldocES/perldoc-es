#!/usr/bin/env perl
#
# actualizar_archivos.pl
#
# · lleva los documentos traducidos nuevos o con cambios al translated/
# · borra el que está en translated/ si es igual al que está en reviewed/
#	(eso quiere decir que los que están en reviewed/ se ponen "a mano")
# · genera un informe con el estado actual (documentos nuevos o con cambios)
# · copia la memoria de traducción al directorio del proyecto
# · copia el diccionario de nuevas palabras al dir. del proy.
#
# TODO: ¿Es posible automatizar los comandos git, o seguimos a mano? Mejor a mano... de momento.

# Joaquín Ferrero. 20210524
# Última versión:  20210614
#
# Se supone que se debe ejecutar este programa después de haber ejecutado la orden
# de generar los ficheros finales en el OmegaT, pero no es imprescindible.
#
use v5.28.0;
use utf8;
use locale;						# localización de la ordenación de cadenas; formateo de números
use autodie;
use open IO => qw':std :locale';			# E/S según localización regional

use Path::Tiny;						# operaciones con archivos
use Digest::MD5 qw(md5_hex);
use POSIX qw'strftime locale_h';

#use Data::Printer array_max => 5;


## Configuración ------------------------------------------------------------------------------------------------------
my $PERL_VERSION	= 'v5.24.0';						# versión Perl de trabajo
my $USER	 	= 'explorer';						# archivo TMX con la memoria de trabajo del usuario
my $DIR_ROOT	 	= path("/home/$USER/Proyectos/perldocES/v5");		# ruta al directorio principal

my $DIR_GIT	 	= $DIR_ROOT->child("perldoc-es.github");		# ruta al repositorio local Github
my $PROJECT	 	= 'work.github';					# directorio de trabajo
my $DIR_PROJECT	 	= $DIR_ROOT->child($PROJECT);				# ruta al directorio de trabajo

my $FILE_LIST	 	= $DIR_PROJECT->child("files.lst");			# ruta al archivo con las descripciones
my $FILE_STATS	 	= $DIR_PROJECT->child("omegat/project_stats.txt");	# ruta al archivo con las estadísticas
my $FILE_STATS_OLD	= $DIR_ROOT->child("tools/project_stats.txt");		# ruta al archivo con las estadísticas anterior

my $DIR_GIT_TRANS	= $DIR_GIT->child("pod/translated");
my $DIR_GIT_REVIEW	= $DIR_GIT->child("pod/reviewed");
my $DIR_GIT_TMX		= $DIR_GIT->child("memory/work");

my %archivos_que_no_cuentan = (
    'perlapi.pod'	=> 1,
    'perlapio.pod'	=> 1,
    'perlcall.pod'	=> 1,
    'perldebguts.pod'	=> 1,
    'perldiag.pod'	=> 1,
    'perlebcdic.pod'	=> 1,
    'perlgpl.pod'	=> 1,
    'perlguts.pod'	=> 1,
    'perlintern.pod'	=> 1,
    'perliol.pod'	=> 1,
    'perlreapi.pod'	=> 1,
    'perlreguts.pod'	=> 1,
    'perluniprops.pod'	=> 1,
#    'perlxstut.pod'	=> 1,
    'perlxstypemap.pod'	=> 1,
);
## Fin de configuración -----------------------------------------------------------------------------------------------

## Comprobación ---------------------------------------------------------------
$FILE_LIST->exists      or die "ERROR: No encuentro el listado de archivos [$FILE_LIST]\n";
$FILE_STATS->exists     or die "ERROR: No encuentro el archivo de estadísticas [$FILE_STATS]\n";
$FILE_STATS_OLD->exists or $FILE_STATS->copy($FILE_STATS_OLD);


## Leer el fichero de descripciones -------------------------------------------

# clave: nombre del archivo
# valor: descripción del archivo
say "Leer archivo de descripciones...";
my %pod_descripción_de = map { split " ", $_, 2; } $FILE_LIST->lines({ chomp => 1 });


## Leer el fichero de estadísticas --------------------------------------------
# clave: nombre del archivo
# valor: estadísticas de traducción del archivo: [  [ ]  ]
# seg.|seg. pend.|unicos|unic. pend.|palabras|pal. pend.|unicas|unicas pend.
# 0    1          2      3           4        5          6      7

say "Leer archivo de estadísticas...";
my %estadísticas;
for ( $FILE_STATS->lines ) {
    my @campos = split;
    next if @campos != 17;
    $estadísticas{ $campos[0] } = [ @campos[ 1..8 ] ];
}

say "Leer archivo anterior de estadísticas...";
my %estadísticas_anteriores;
for ( $FILE_STATS_OLD->lines ) {
    my @campos = split;
    next if @campos != 17;
    $estadísticas_anteriores{ $campos[0] } = [ @campos[ 1..8 ] ];
}

#chdir $DIR_GIT;
#say qx(git pull);


# Ver cambios en los archivos --------------------------------------------------
my %archivos_traducidos_nuevos;
my %archivos_traducidos_cambios;
my %archivos_cambios;
my %archivos_traduciendo;
#my %archivos_porciento;
my $total_segmentos = 0;
my $total_segmentos_traducidos = 0;
#my $min_porcen	   = 30;			# Porcentaje mínimo docs traducidos, no asignados
my @files_changed;				# archivos que han cambiado


foreach my $fichero (sort keys %pod_descripción_de) {
    if (exists $estadísticas{$fichero}) {
	my $hay_cambios;

	# Recorrer las filas de estadísticas de $fichero, y ver los cambios
	for my $j (1 .. 8) {
	    if ($estadísticas{$fichero}[$j] != $estadísticas_anteriores{$fichero}[$j]) {
		$hay_cambios++;
	    	last;
	    }
	}

	# si hay cambios, lo marcamos como $fichero cambiado
	if ($hay_cambios) {
	    if ($estadísticas{$fichero}[1] == 0) {
		$archivos_traducidos_cambios{$fichero} = 1;
	    }
	    else {
		$archivos_cambios{$fichero} = 1;
	    }

	    say "Actualizando $fichero";
	    push @files_changed, $fichero;
	}

	# si está completamente traducido, lo llevamos al git
	if ($estadísticas{$fichero}[1] == 0) {

	    my $origen  = $DIR_PROJECT->child("/target/$fichero");
	    my $targetT = $DIR_GIT_TRANS->child($fichero);
	    my $targetR = $DIR_GIT_REVIEW->child($fichero);

	    my $nuevo_md5 = md5_hex($origen->slurp_raw);
	    my $trans_md5 = -f $targetT ? md5_hex($targetT->slurp_raw) : 0;
	    my $revie_md5 = -f $targetR ? md5_hex($targetR->slurp_raw) : 0;

	    my $aviso_movido = 0;

	    # llevar a translated/ si no hay o está cambiado
	    if (    (!-f $targetT  or  $nuevo_md5 ne $trans_md5)
		and (!-f $targetR  or  $nuevo_md5 ne $revie_md5)
	    ) {
		# Marcado en el informe
		if (!-f $targetT  and  !-f $targetR) {			# si no estaba en translated/ ni en reviewed/
		    $archivos_traducidos_nuevos{$fichero} = 1;		# marcar como nuevo
		    delete $archivos_traducidos_cambios{$fichero};
		    delete $archivos_cambios{$fichero};
		}
		else {
		    $archivos_traducidos_cambios{$fichero} = 1;		# marcar solo como que cambió
		}

                # Copiar a destino
		$aviso_movido++;
		say "Copiando $origen a $targetT";
		$origen->copy($targetT)  or  die "ERROR: $!\n";		# llevar a translated/
		# TODO : git add pod/translated/$fichero

		# NOTE : ¿Realmente es necesario eliminar los documentos en translated/?
		# Es decir, ¿no podemos mantener los mismos archivos en los dos sitios?
		# La sola presencia en reviewed/ es un indicativo de que está revisado.

		# Ver ahora si el nuevo translated/ == reviewed/
		$trans_md5 = -f $targetT ? md5_hex($targetT->slurp_raw) : 0;

		if ($revie_md5  and  $revie_md5 eq $trans_md5) {	# sí, el movido es igual
		    say "Eliminar $targetT";
		    $targetT->remove;					# borramos de translated/
		    $aviso_movido = 0;
		    delete $archivos_traducidos_cambios{$fichero};	# no hay ningún cambio
		    delete $archivos_cambios{$fichero};
		}
	    }
	    else {
		delete $archivos_traducidos_cambios{$fichero};
		delete $archivos_cambios{$fichero};
	    }

	    if ($aviso_movido) {
		say "$fichero => git";
	    }
	}
	
	my $porcentaje = 100 * (1 - ($estadísticas{$fichero}[1] / $estadísticas{$fichero}[0]));

	if ($fichero !~ /delta/  and  not exists($archivos_que_no_cuentan{$fichero})  and  $estadísticas{$fichero}[1] > 0) { #  and  $porcentaje >= $min_porcen) {
	    $archivos_traduciendo{$fichero} = $porcentaje;
	}
	if ( ( $fichero !~ /delta/  and  not exists($archivos_que_no_cuentan{$fichero}) )  or  $porcentaje == 100) {
	    $total_segmentos += $estadísticas{$fichero}[0];
	    $total_segmentos_traducidos += $estadísticas{$fichero}[1];
	}
#	if ($porcentaje != 100  and  $porcentaje >= $min_porcen) {
#	    $archivos_porciento{$fichero} = $porcentaje;
#	}
    }
}

#p %archivos_traducidos_nuevos, as => "archivos_traducidos_nuevos";
#p %archivos_traducidos_cambios, as => "archivos_traducidos_cambios";
#p %archivos_cambios, as => "archivos_cambios";
#p %archivos_traduciendo, as => "archivos_traduciendo";
#p %archivos_porciento, as => "archivos_porciento";

## Sacar el informe -----------------------------------------------------------
my $informe = $DIR_ROOT . "/informes/informe_" . strftime("%Y%m%d", localtime);

while (-f "$informe.txt") {				# evitar sobreescribir informes en el mismo día
    if ($informe !~ s/\d_\K(\d+)$/$1+1/e) {
	$informe .= '_1';
    }
}

open my $REPORT, '>', "$informe.txt";

say $REPORT "\nNuevos archivos traducidos:\n";
for my $archivo (sort keys %archivos_traducidos_nuevos) {
    say $REPORT "\t$archivo";
}

say $REPORT "\nArchivos traducidos que han cambiado:\n";
for my $archivo (sort keys %archivos_traducidos_cambios) {
    say $REPORT "\t$archivo";
}

say $REPORT "\nArchivos con nuevos segmentos traducidos:\n";
for my $archivo (sort keys %archivos_cambios) {
    say $REPORT "\t$archivo";
}

say $REPORT "\nArchivos en traducción:\n";
for my $archivo (sort keys %archivos_traduciendo) {
    my $porcentaje = $archivos_traduciendo{$archivo};
    printf $REPORT "\t%-22s (%3d %%)\n",  $archivo, $porcentaje;
}

#say $REPORT "\nArchivos con un mínimo del $min_porcen %:\n";
#for my $archivo (sort keys %archivos_porciento) {
#    my $porcentaje = $archivos_porciento{$archivo};
#    printf $REPORT "\t%-22s (%3d %%)\n", $archivo, $porcentaje;
#}

## Sacar los totales
setlocale(LC_NUMERIC, "");

my $total = sprintf "%.2f %%", 100 * (1  -  $total_segmentos_traducidos / $total_segmentos);
say $REPORT "\n\nEl proyecto está al $total";

close $REPORT;

# Copiar las estadísticas para la próxima vez.
$FILE_STATS->copy($FILE_STATS_OLD);

#-------------------------------------------------------------------------------
my $archivos_en_git = 0;

## Llevar la memoria de traducción al git
my $origen = $DIR_PROJECT->child("$PROJECT-omegat.tmx");
my $target = $DIR_GIT_TMX->child("perlspanish-omegat.$USER.tmx");

if (!-f $target or  -M $origen < -M $target) {
    say "Memoria de traducción => git";
    $origen->copy($target) or die "ERROR: $!\n";
    # TODO : git add memory/work/perlspanish-omegat.explorer.tmx
    $archivos_en_git++;
}

# Llevar el fichero de palabras nuevas
$origen = $DIR_PROJECT->child("omegat/learned_words.txt");
$target = $DIR_GIT->child("omegat_stuff/omegat/learned_words.txt");

if (!-f $target  or  -M $origen < -M $target) {
    say "Palabras nuevas en diccionario personal => git";
    $origen->copy($target) or die "ERROR: $!\n";
    # TODO : git add ?
    $archivos_en_git++;
}

# Llevar el fichero de palabras nuevas traducidas
$origen = $DIR_PROJECT->child("/glossary/glossary.txt");
$target = $DIR_GIT->child("/omegat_stuff/glossary/glossary.txt");

if (!-f $target  or  -M $origen < -M $target) {
    say "Palabras nuevas en glosario personal => git";
    $origen->copy($target) or die "ERROR: $!\n";
    # TODO : git add ?
    $archivos_en_git++;
}

if ($archivos_en_git) {
    my $fecha = strftime("%Y.%m.%d %H.%M", localtime);
    my $files_changed = join " ", @files_changed;
    say "Archivos que han cambiado => git [$files_changed]";
    # TODO : git commit -a -m "$PERL_VERSION $USER $fecha $files_changed"
}

###############################################################################
__END__
