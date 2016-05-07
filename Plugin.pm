#!/usr/bin/perl
# $Id$
#
# Handles server side file type conversion and resampling.
# Replace custom-convert.conf.
#
# To be used mainly with Squeezelite-R2 
# (https://github.com/marcoc1712/squeezelite/releases)
#
# Logitech Media Server Copyright 2001-2011 Logitech.
# This Plugin Copyright 2015 Marco Curti (marcoc1712 at gmail dot com)
#
# C3PO is inspired by the DSD Player Plugin by Kimmo Taskinen <www.daphile.com>
# and Adrian Smith (triode1@btinternet.com), but it  does not replace it, 
# DSD Play is still needed to play dsf and dff files.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
################################################################################

package Plugins::C3PO::Plugin;

use strict;
use warnings;

use FindBin qw($Bin);
use lib $Bin; #not needed here, we just neeed to know $Bin

use Data::Dump qw(dump pp);
use File::Spec::Functions qw(:ALL);
use File::Basename;

my $serverFolder;
my $pluginPath;
my $C3POfolder;

#use lib rel2abs(catdir($C3POfolder, 'lib'));
#use lib rel2abs(catdir($C3POfolder,'CPAN'));

# sub and BEGIN block is needed to avoid PERL claims 
# in Linux but not in windows.

sub getLibDir {
	my $lib = shift;
	
	$serverFolder	= $Bin;
	$pluginPath		=__FILE__;
	$C3POfolder		= File::Basename::dirname($pluginPath);
	my $str= catdir($C3POfolder, $lib);
	my $dir = rel2abs($str);
	return $dir;

}

BEGIN{ use lib getLibDir('lib');}

require File::HomeDir;

use base qw(Slim::Plugin::Base);

if ( main::WEBUI ) {
	require Plugins::C3PO::Settings;
	require Plugins::C3PO::PlayerSettings;
}

use Plugins::C3PO::Shared;
use Plugins::C3PO::Logger;
use Plugins::C3PO::Transcoder;
use Plugins::C3PO::OsHelper;
use Plugins::C3PO::FfmpegHelper;
use Plugins::C3PO::FlacHelper;
use Plugins::C3PO::FaadHelper;
use Plugins::C3PO::SoxHelper;
use Plugins::C3PO::Utils::Config;
use Plugins::C3PO::Utils::File;
use Plugins::C3PO::Utils::Log;

use Plugins::C3PO::Formats::Format;
use Plugins::C3PO::Formats::Wav;
use Plugins::C3PO::Formats::Aiff;
use Plugins::C3PO::Formats::Flac;
use Plugins::C3PO::Formats::Alac;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Player::TranscodingHelper;

my $class;
my $preferences = preferences('plugin.C3PO');
my $serverPreferences = preferences('server');

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.C3PO',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_C3PO_MODULE_NAME',
} );

##
#
# C-3PO capabilities
#
# codecs/formats supported or filtered.
#
my %supportedCodecs=();
$supportedCodecs{'wav'}{'supported'}=1;
$supportedCodecs{'wav'}{'defaultEnabled'}=1;
$supportedCodecs{'wav'}{'defaultEnableSeek'}=1;
$supportedCodecs{'wav'}{'defaultEnableStdin'}=0;
$supportedCodecs{'aif'}{'supported'}=1;
$supportedCodecs{'aif'}{'defaultEnabled'}=1;
$supportedCodecs{'aif'}{'defaultEnableSeek'}=0;
$supportedCodecs{'aif'}{'defaultEnableStdin'}=0;
$supportedCodecs{'flc'}{'supported'}=1;
$supportedCodecs{'flc'}{'defaultEnabled'}=1;
$supportedCodecs{'flc'}{'defaultEnableSeek'}=0;
$supportedCodecs{'flc'}{'defaultEnableStdin'}=1;
$supportedCodecs{'alc'}{'supported'}=1;
$supportedCodecs{'alc'}{'defaultEnabled'}=1;
$supportedCodecs{'alc'}{'defaultEnableSeek'}=0;
$supportedCodecs{'alc'}{'defaultEnableStdin'}=0;
$supportedCodecs{'loc'}{'unlisted'}=1;
$supportedCodecs{'pcm'}{'unlisted'}=1;
$supportedCodecs{'dff'}{'supported'}=0;
$supportedCodecs{'dsf'}{'supported'}=0;

my %previousCodecs=();

#
# samplerates
#
# List could be extended if and when some new player with higher capabilities 
# will be introduced, this is from squeezeplay.pm at 10/10/2015.
#
# my %pcm_sample_rates = (
#	  8000 => '5',
# 	 11025 => '0',
#	 12000 => '6',
#	 16000 => '7',
#	 22050 => '1',
#	 24000 => '8',
#	 32000 => '2',
#	 44100 => '3',
#	 48000 => '4',
#	 88200 => ':',
#	 96000 => '9',
#	176400 => ';',
#	192000 => '<',
#	352800 => '=',
#	384000 => '>',
#);
my %OrderedsampleRates = (
	"a" => 8000,
	"b" => 11025,
	"c" => 12000,
	"d" => 16000,
	"e" => 22050,
	"f" => 24000,
	"g" => 32000,
	"h" => 44100,
	"i" => 48000,
	"l" => 88200,
	"m" => 96000,
	"n" => 176400,
	"o" => 192000,
	"p" => 352800,
	"q" => 384000,
	"r" => 705600,
	"s" => 768000,
);

my $capabilities={};
$capabilities->{'codecs'}=\%supportedCodecs;
$capabilities->{'samplerates'}=\%OrderedsampleRates;

my $C3POwillStart=0;
my $C3POisDownloading=0;

my $logFolder;
my $pathToPrefFile;
my $pathToPerl;
my $pathToC3PO_pl;
my $pathToC3PO_exe;
my $pathToHeaderRestorer_pl;
my $pathToHeaderRestorer_exe;
my $pathToFlac;
my $pathToSox;
my $pathToFaad;
my $pathToFFmpeg;

my $soxVersion;

#
###############################################
## required methods

sub getDisplayName {
	return 'PLUGIN_C3PO_MODULE_NAME';
}
	
sub initPlugin {
	$class = shift;

	$class->SUPER::initPlugin(@_);
	
	if (main::INFOLOG && $log->is_info) {
		$log->info('initPlugin');
	}

	if ( main::WEBUI ) {
		Plugins::C3PO::Settings->new($class);
		Plugins::C3PO::PlayerSettings->new($class);
	}
	
	_initPreferences();

	#check codec list.
	my $codecList=_initCodecs();
		
	#check File location at every startup.
	$class->_initFilesLocations();
	
	#test if C-3PO will raise up on call.
	$C3POwillStart=$class->_testC3PO();

	#Store them as preferences to be retieved and used by C3PO.
	$preferences->set('pathToPerl', $pathToPerl);
	$preferences->set('pathToC3PO_exe', $pathToC3PO_exe);
	$preferences->set('pathToC3PO_pl', $pathToC3PO_pl);
	
	$preferences->set('C3POwillStart', $C3POwillStart);
	
	$preferences->set('pathToHeaderRestorer_pl', $pathToHeaderRestorer_pl);
	$preferences->set('pathToHeaderRestorer_exe', $pathToHeaderRestorer_exe);
	
	$preferences->set('serverFolder', $serverFolder);
	$preferences->set('logFolder', $logFolder);
	$preferences->set('C3POfolder', $C3POfolder);
	
	$preferences->set('pathToPrefFile', $pathToPrefFile);
	
	$preferences->set('pathToFlac', $pathToFlac);
	$preferences->set('pathToSox', $pathToSox);
	$preferences->set('pathToFaad', $pathToFaad);
	$preferences->set('pathToFFmpeg', $pathToFFmpeg);

	$preferences->set('soxVersion', $soxVersion);
	
	_disableProfiles();

	# Subscribe to new client events
	Slim::Control::Request::subscribe(
		\&newClientCallback, 
		[['client'], ['new']],
	);
	
	# Subscribe to reconnect client events
	Slim::Control::Request::subscribe(
		\&clientReconnectCallback, 
		[['client'], ['reconnect']],
	);
}
sub shutdownPlugin {
	Slim::Control::Request::unsubscribe( \&newClientCallback );
	Slim::Control::Request::unsubscribe( \&clientReconnectCallback );
}

sub newClientCallback {
	my $request = shift;
	my $client  = $request->client() || return;
	
	return _clientCalback($client,"new");
}

sub clientReconnectCallback {
	my $request = shift;
	my $client  = $request->client() || return;
	
	return _clientCalback($client,"reconnect");
}
###############################################################################
## Public
##
sub getLog{
	
	return $log;
}

sub getSharedPrefNameList(){
	return Plugins::C3PO::Shared::getSharedPrefNameList();
}

sub getPreferences{
	
	$preferences = preferences('plugin.C3PO');
	return $preferences;
}

sub getCapabilities{
	return $capabilities;
}

sub refreshClientPreferences{
	my $class = shift;
	my $client = shift;
	
	_initPreferences($client);

	return $preferences;
}

sub translateSampleRates{
	my $class = shift;
	my $in = shift;
	
	my $caps=getCapabilities();
	my $ref= $caps->{'samplerates'};
	
	my $map={};
	my $out={};
	
	for my $k (keys %$ref){
		
		my $value=$ref->{$k};
		
		$map->{$k}=$value;
		$map->{$value}=$k;
	}
	
	for my $k (keys %$in){

		my $value=$in->{$k};
		my $transKey = $map->{$k};
		
		$out->{$transKey}=$value;
	}
	return $out;
	
}
sub initClientCodecs{
	my $class = shift;
	my $client = shift;
	
	if (main::DEBUGLOG && $log->is_debug) {
		$log->debug('initClientCodecs');	
	}
	
	my $prefs= getPreferences($client);
	my $codecList="";
	my $prefCodecs;
	my $prefEnableSeek;
	my $prefEnableStdin;
	my $prefEnableConvert;
	my $prefEnableResample;

	if (!defined($prefs->client($client)->get('codecs'))){
	
		($prefCodecs, $prefEnableSeek,$prefEnableStdin,
		 $prefEnableConvert,$prefEnableResample) = _defaultClientCodecs($client);

	} else {
		
		($prefCodecs, $prefEnableSeek,$prefEnableStdin,
		 $prefEnableConvert,$prefEnableResample) = _refreshClientCodecs($client);
	}
	#build the complete list string
	for my $codec (keys %$prefCodecs){

		if (length($codecList)>0) {

			$codecList=$codecList." ";
		}
		$codecList=$codecList.$codec;
	}
	$prefs->client($client)->set('codecs', $prefCodecs);
	$prefs->client($client)->set('enableSeek', $prefEnableSeek);
	$prefs->client($client)->set('enableStdin', $prefEnableStdin);
	$prefs->client($client)->set('enableConvert', $prefEnableConvert);
	$prefs->client($client)->set('enableResample', $prefEnableResample);

	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug("New codecs: ".dump($prefCodecs));
	}
	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug("New preferences: ".dump($prefs->client($client)->get('codecs')));
	}
	
	return ($codecList);
}

sub settingsChanged{
	my $class = shift;
	my $unusedClient=shift;
	# it takes so little rebuild profiles for any player...
	
	my $prefs= getPreferences();
	
	if (main::DEBUGLOG && $log->is_debug) {	
			my $conv = Slim::Player::TranscodingHelper::Conversions();
			my $caps = \%Slim::Player::TranscodingHelper::capabilities;
			$log->debug("STATUS QUO ANTE: ");
			$log->debug("LMS conversion Table:   ".dump($conv));
			$log->debug("LMS Capabilities Table: ".dump($caps));
	}
	
	if (main::DEBUGLOG && $log->is_debug) {
		$log->debug("preferences:");
		$log->debug(dump Plugins::C3PO::Shared::prefsToHash($prefs));
	}
	
	_disableProfiles();
	
	if (main::DEBUGLOG && $log->is_debug) {	
			my $conv = Slim::Player::TranscodingHelper::Conversions();
			my $caps = \%Slim::Player::TranscodingHelper::capabilities;
			$log->debug("AFTER PROFILES DISABLING: ");
			$log->debug("LMS conversion Table:   ".dump($conv));
			$log->debug("LMS Capabilities Table: ".dump($caps));
	}

	my @clientList = Slim::Player::Client::clients();

	for my $client (@clientList){
		
		_playerSettingChanged($client);
		
	}
	if (main::DEBUGLOG && $log->is_debug) {	
			my $conv = Slim::Player::TranscodingHelper::Conversions();
			my $caps = \%Slim::Player::TranscodingHelper::capabilities;
			$log->debug("RESULT: ");
			$log->debug("LMS conversion Table:   ".dump($conv));
			$log->debug("LMS Capabilities Table: ".dump($caps));
	}
}
sub getStatus{
	my $class = shift;
	my $client=shift;
	
	my $displayStatus;
	my $status;
	my $message;
	
	my $in = _calcStatus();
	my %statusTab=();
	my %details=();
	
	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug(dump($in));
	}
	for my $dest (keys %$in) {
		
		 if (($client && ($dest eq $client || $dest eq 'all')) ||
		     (!$client && ($dest eq 'server' || $dest eq 'all'))) {
			
			my $stat = $in->{$dest};
			for my $st (keys %$stat){
			
				$statusTab{$st} = $stat->{$st}
				
			}
		 }
	}
	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug(dump(%statusTab));
	}
	if (scalar(keys %statusTab)== 0){
		
		$displayStatus=0;
		$status= Slim::Web::HTTP::CSRF->protectName('PLUGIN_C3PO_STATUS');
		$message= Slim::Web::HTTP::CSRF->protectName('PLUGIN_C3PO_STATUS_000');
	
	} elsif (scalar (keys %statusTab) == 1){
		
		my @stat = (keys %statusTab);
		my $st= shift @stat;
		
		$displayStatus=1;
		$status = $statusTab{$st}{'status'};
		$message= $statusTab{$st}{'message'};
		
	} else{
		#use the worst status as message.
		$status = Slim::Web::HTTP::CSRF->protectName('PLUGIN_C3PO_STATUS');
		my $seen=0;
		foreach my $st (sort keys %statusTab){
			
			if (! $seen){
				$message= $statusTab{$st}{'status'};
			}
			$details{$st}= $statusTab{$st}{'message'};
		}
		$displayStatus=1;
	} 
	my %out= ();
	
	$out{'display'}=$displayStatus;
	$out{'status'}=$status;
	$out{'message'}=$message;
	$out{'details'}=\%details;
	
	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug(dump(%out));
	}
	
	return \%out;
}
sub setWinExecutablesStatus{
	my $class = shift;
	my $status= shift;
	
	if (main::INFOLOG && $log->is_info) {
			 $log->info(dump('Win Executables Status: '));
			 $log->info(dump($status));
	}
	if ($status->{'code'} > 0){ #Error
	
		$C3POisDownloading=0;

	} elsif ($status->{'code'} == 0){ #download Ok;
		
		$class->initPlugin();
		settingsChanged();
		
	}
	if ( main::WEBUI ) {
			Plugins::C3PO::Settings->refreshStatus();
			Plugins::C3PO::PlayerSettings->refreshStatus();
	}

}
################################################################################
## Private 
##
sub _initPreferences{
	my $client	= shift;
	
	my $curentVersion	= _getCurrentVersion();
	my $prefVersion;
	
	if ($client){
	
		$prefVersion = $preferences->client($client)->get('version');
		
	} else {
	
		$prefVersion = $preferences->get('version');
	}
	
	if (!$prefVersion){$prefVersion = 0};
	
	if (main::INFOLOG && $log->is_info) {
	
		if ($client){
			$log->info(" Prefs version: ".$prefVersion);
		} else{
			$log->info("Prefs version: ".$prefVersion);
		}
	}
	if ($curentVersion > $prefVersion){
		
		_migratePrefs($curentVersion, $prefVersion, $client);
		
	} elsif ($prefVersion > $curentVersion){
	
		$log->warn("C-3PO version is: ".$curentVersion.", preference Version is: ".$prefVersion." Could not migrate back");
	}
	
	if (! $client){
	
		_initServicePreferences();
	
	} elsif  ($preferences->client($client)->get('useGlogalSettings')){

		for my $item (Plugins::C3PO::Shared::getSharedPrefNameList()){
			$preferences->client($client)->set($item, $preferences->get($item));
		}
	}
}

sub _migratePrefs{
	my $curentVersion	= shift;
	my $prefVersion		= shift;
	my $client			= shift;
	
	if (main::INFOLOG && $log->is_info) {
	
		if ($client){
			$log->info("_migratePrefs for client: ".$client." from: ".$prefVersion." to: ".$curentVersion);
		} else{
			$log->info("_migratePrefs from: ".$prefVersion." to: ".$curentVersion);
		}
	}
	
	if ($prefVersion == 0 && !($preferences->get('outCodec'))){
	
		#C-3PO is running for the first time
		_initDefaultPrefs($client);

	} elsif ($prefVersion == 0){
	
		 #C-3PO was running prior v. 1.1.03
		 
		if ($client){
		
			if  (! $preferences->client($client)->get('useGlogalSettings')){

				# some adjustement from version 1.0 to 1.1

				if ($preferences->client($client)->get('extra')){
					$preferences->client($client)->set('extra_after_rate', $preferences->client($client)->get('extra'));
				}
				
				if (!($preferences->client($client)->get('ditherType')) || 
					 $preferences->client($client)->get('ditherType') eq "X" ){

					if (!$preferences->client($client)->get('dither')){
						$preferences->client($client)->set('ditherType', -1);
					} else {
						$preferences->client($client)->set('ditherType', 1);
					}
					
					$preferences->set('ditherPrecision', -1);
				}
				
				# some adjustement for 1.1.2

				if (! $preferences->client($client)->get('loudnessRef')){
					$preferences->client($client)->set('headroom', $preferences->get('headroom'));
					$preferences->client($client)->set('loudnessGain', $preferences->get('loudnessGain'));
					$preferences->client($client)->set('loudnessRef', $preferences->get('loudnessRef'));
					$preferences->client($client)->set('remixLeft', $preferences->get('remixLeft'));
					$preferences->client($client)->set('remixRight', $preferences->get('remixRight'));
					$preferences->client($client)->set('flipChannels', $preferences->get('flipChannels'));			
				}
			}
			
			$preferences->client($client)->remove( 'outEncoding' );
			$preferences->client($client)->remove( 'outChannels' );
			$preferences->client($client)->remove( 'extra' );
			$preferences->client($client)->remove( 'dither' );

		} else { #server
		 
			$preferences->init({				
			   headroom					=> "1",
			   gain						=> 0,
			   loudnessGain				=> 0,
			   loudnessRef					=> 65,
			   remixLeft					=> 100,
			   remixRight					=> 100,
			   flipChannels				=> "0",
			   extra_before_rate			=> "",
			   extra_after_rate			=> "",
		   });

			# some adjustement from version 1.0 to 1.1

		   if ($preferences->get('extra')){
			   $preferences->set('extra_after_rate', $preferences->get('extra'));
		   }
		   if (! $preferences->get('ditherType')){
		   
			   if (!$preferences->get('dither')){
				   $preferences->set('ditherType', -1);
			   } else {
				   $preferences->set('ditherType', 1);
			   }
			  $preferences->set('ditherPrecision', -1);
		   }
		   		   
		   $preferences->remove( 'outEncoding' );
		   $preferences->remove( 'outChannels' );
		   $preferences->remove( 'extra' );
		   $preferences->remove( 'dither' );

	    } 
		
	} else { #here specifc advancements from versions greather than 1.1.02

	}
	
	if ($client){
	
		$preferences->client($client)->set('version',$curentVersion);
	
	} else{
	
		$preferences->set('version',$curentVersion);
	}
	$preferences->writeAll();
	$preferences->savenow();
	
	if ($client){
	
		$prefVersion = $preferences->client($client)->get('version');
		
	} else {
	
		$prefVersion = $preferences->get('version');
	}
	
	if (main::INFOLOG && $log->is_info) {
	
		if ($client){
			$log->info(" Prefs for client: ".$client." migrated to: ".$prefVersion);
		} else{
			$log->info("Prefs mugrated to: ".$prefVersion);
		}
	}
}
sub _initServicePreferences{

	$preferences->init({
		serverFolder				=> $serverFolder,
		logFolder					=> $logFolder,
		pathToPrefFile				=> $pathToPrefFile,
		pathToFlac					=> $pathToFlac,
		pathToSox					=> $pathToSox,
		pathToFaad					=> $pathToFaad,
		pathToFFmpeg				=> $pathToFFmpeg,
		pathToC3PO_pl				=> $pathToC3PO_pl,
		pathToC3PO_exe				=> $pathToC3PO_exe,
		C3POfolder					=> $C3POfolder,
		pathToPerl					=> $pathToPerl,
		soxVersion					=> $soxVersion,
		C3POwillStart				=> $C3POwillStart,
		pathToHeaderRestorer_pl		=> $pathToHeaderRestorer_pl,
		pathToHeaderRestorer_exe	=> $pathToHeaderRestorer_exe,
	});
}
sub _initDefaultPrefs{
	my $client			= shift;
	
	# sets default values for 'real' preferences.
	
	if ($client){
	
		$preferences->client($client)->set('useGlogalSettings', 'on');
	
	} else {
	
		$preferences->init({
			resampleWhen				=> "A",
			resampleTo					=> "S",
			outCodec					=> "wav",
			outBitDepth					=> 3,
			#outEncoding				=> undef,
			#outChannels				=> 2,
			headroom					=> "1",
			gain						=> 0,
			loudnessGain				=> 0,
			loudnessRef					=> 65,
			remixLeft					=> 100,
			remixRight					=> 100,
			flipChannels				=> "0",
			quality						=> "v",
			phase						=> "I",
			aliasing					=> "0",
			bandwidth					=> 907,
			#dither						=> "on",
			ditherType					=> "1",
			ditherPrecision				=> -1,
			#extra						=> "",
			extra_before_rate			=> "",
			extra_after_rate			=> "",
		});
	}
}

sub _getCurrentVersion{
	my $plugins = Slim::Utils::PluginManager->allPlugins;
	
	my $currentVersion;
	
	for my $plugin (keys %$plugins) {

		if ($plugin eq 'C3PO'){
			my $entry = $plugins->{$plugin};
			$currentVersion = $entry->{'version'};
			last;
		}
	}
	my $version = _unstringVersion($currentVersion);
	
	if (main::INFOLOG && $log->is_info) {
		$log->info("C-3PO version is: ".$version);
	}
	return $version;
}
sub _initFilesLocations {
	my $class = shift;

	$logFolder		= Slim::Utils::OSDetect::dirsFor('log');
	$pathToPrefFile = catdir(Slim::Utils::OSDetect::dirsFor('prefs'), 'plugin', 'C3PO.prefs');
	
	$pathToPerl     = Slim::Utils::Misc::findbin("perl");
	$pathToC3PO_pl	= catdir($C3POfolder, 'C-3PO.pl');
	$pathToC3PO_exe = Slim::Utils::Misc::findbin("C-3PO");
	
	$pathToFlac     = Slim::Utils::Misc::findbin("flac");
	$pathToSox      = Slim::Utils::Misc::findbin("sox");
	$pathToFaad     = Slim::Utils::Misc::findbin("faad");
	$pathToFFmpeg   = Slim::Utils::Misc::findbin("ffmpeg");
	
	$soxVersion		= _getSoxVersion();
	$pathToHeaderRestorer_pl  = catdir($C3POfolder, 'HeaderRestorer.pl');
	$pathToHeaderRestorer_exe = Slim::Utils::Misc::findbin("HeaderRestorer");	
}

sub _testC3PO{
	my $class = shift;
	
	my $exe			= _testC3POEXE();
	my $pl			= 0;
	
	if (!$exe){

		if (main::ISWINDOWS){

			require Plugins::C3PO::WindowsDownloader;
			Plugins::C3PO::WindowsDownloader->download($class);
			$C3POisDownloading=1;
		}
				
		$pl= _testC3POPL();
	}
	
	if ($exe){
	
		if (main::INFOLOG && $log->is_info) {
			 $log->info('using C-3PO executable: '.$pathToC3PO_exe);
		}
		return 'exe';
		
	} elsif ($pl) {
	
		if (main::INFOLOG && $log->is_info) {
			 $log->info('using installed perl to run C-3PO.pl');
			 $log->info('perl    : '.$pathToPerl);
			 $log->info('C-3PO.Pl: '.$pathToC3PO_pl);
		}
		return 'pl';
		
	} elsif ($C3POisDownloading){
	
		if (main::INFOLOG && $log->is_info) {
			
			$log->info('Please wait for C-3PO.exe to download: ');
		}
		return 0;
	}
	
	$log->warn('WARNING: C3PO will not start on call: ');
	$log->warn('WARNING: Perl path: '.$pathToPerl);
	$log->warn('WARNING: C-3PO.pl path: '.$pathToC3PO_pl);
	$log->warn('WARNING: C-3PO path: '.$pathToC3PO_exe);
	
	return 0;
}
sub _getSoxVersion{

	if  (! $pathToSox || ! (-e $pathToSox)){
		$log->warn('WARNING: wrong path to SOX  - '.$pathToSox);
		return 0;
	}
	my $command= qq("$pathToSox" --version);
	$command= Plugins::C3PO::Shared::finalizeCommand($command);
	
	my $ret= `$command`;
	my $err=$?;
	
	if (!$err==0){
		$log->warn('WARNING: '.$err.' '.$ret);
		return undef;
	}
	
	my $i = index($ret, "SoX v");
	my $versionString= substr($ret,$i+5);
	
	my $version = _unstringVersion($versionString);
	
	if (main::INFOLOG && $log->is_info) {
		$log->info("Sox path  is: ".$pathToSox);
		$log->info("Sox version is: ".$version);
	}
	return $version;
}

sub _unstringVersion{
	my $versionString = shift;
	
	my @versionArray = split /[.]/, $versionString;
	
	if (!(scalar @versionArray) == 3) {
		$log->warn('WARNING: invalid version string: '.$versionString);
		return undef;
	}
	
	my $major=$versionArray[0];
	my $minor=$versionArray[1];
	my $patchlevel=$versionArray[2];
	
	if ($minor*1 > 99 || $patchlevel*1 > 99) {
		$log->warn('WARNING: invalid version string: '.$versionString);
		return undef;
	}
	
	my $version = $major*10000 + $minor *100 + $patchlevel;
	
	if ($version == 0) {
		$log->warn('WARNING: invalid version string: '.$versionString);
		return undef;
	}
	
	return $version;
}
sub _testC3POEXE{

	#test if C3PO.PL will start on LMS calls
	
	if  (! $pathToC3PO_exe || ! (-e $pathToC3PO_exe)){
		#$log->warn('WARNING: wrong path to C-3PO.exe, will not start - '.$pathToC3PO_exe);
		return 0;
	}
		
	my $command= qq("$pathToC3PO_exe" -h hello -l "$logFolder" -x "$serverFolder");
	
	if (! (main::DEBUGLOG && $log->is_debug)) {
	
		$command = $command." --nodebuglog";
	}
	
	if (! (main::INFOLOG && $log->is_info)){
	
		$command = $command." --noinfolog";
	}
	
	$command= Plugins::C3PO::Shared::finalizeCommand($command);
	
	
	if (main::INFOLOG && $log->is_info) {
			 $log->info("command: ".$command);
	}
	
	my $ret= `$command`;
	my $err=$?;
	
	if (!$err==0){
		$log->warn('WARNING: '.$err.$ret);
		return 0;}
	
	if (main::INFOLOG && $log->is_info) {
			 $log->info($ret);
	}
	return 1;
}
sub _testC3POPL{

	#test if C3PO.PL will start on LMS calls
	if  (!(-e $pathToPerl)){
		#$log->warn('WARNING: wrong path to perl, C-3PO.pl, will not start - '.$pathToPerl);
		return 0;
	}
	
	if  (!(-e $pathToC3PO_pl)){
		#$log->warn('WARNING: wrong path to C-3PO.pl, will not start - '.$pathToC3PO_pl);
		return 0;
	}

	my $command= qq("$pathToPerl" "$pathToC3PO_pl" -h hello -l "$logFolder" -x "$serverFolder");
	
	if (! main::DEBUGLOG || ! $log->is_debug) {
	
		$command = $command." --nodebuglog";
	}
	
	if (! main::INFOLOG || ! $log->is_info){
	
		$command = $command." --noinfolog";
	}
	$command= Plugins::C3PO::Shared::finalizeCommand($command);
	
	if (main::INFOLOG && $log->is_info) {
			 $log->info('command: '.$command);
	}
	
	my $ret= `$command`;
	my $err=$?;
	
	if (!$err==0){
		$log->warn('WARNING: '.$err.$ret);
		return 0;}
	
	if (main::INFOLOG && $log->is_info) {
			 $log->info($ret);
	}
	return 1;
}
sub _clientCalback{
	my $client = shift;
	my $type = shift;
	
	$class->refreshClientPreferences($client);
	my $prefs= getPreferences($client);
	
	my $id= $client->id();
	my $macaddress= $client->macaddress();
	my $modelName= $client->modelName();
	my $model= $client->model();
	my $name= $client->name();
	my $maxSupportedSamplerate= $client->maxSupportedSamplerate();
	
	my $samplerateList= _initSampleRates($client);
	my $clientCodecList= $class->initClientCodecs($client);
	
	if (main::INFOLOG && $log->is_info) {
			 $log->info("$type ClientCallback received from \n".
						"id:                     $id \n".
						"mac address:            $macaddress \n".
						"modelName:              $modelName \n".
						"model:                  $model \n".
						"name:                   $name \n".
						"max samplerate:         $maxSupportedSamplerate \n".
						"supported sample rates: $samplerateList \n".
						"supported codecs :      $clientCodecList".
						"");
	}
	#register the new client in preferences.
	$preferences->client($client)->set('id',$id);
	$preferences->client($client)->set('macaddress', $macaddress);
	$preferences->client($client)->set('modelName', $modelName);
	$preferences->client($client)->set('model',$model);
	$preferences->client($client)->set('name', $name);
	$preferences->client($client)->set('maxSupportedSamplerate',$maxSupportedSamplerate);
	
	_setupTranscoder($client);

	return 1;
}

sub _initSampleRates{
	my $client = shift;
	
	my $maxSupportedSamplerate= $client->maxSupportedSamplerate();
	
	my $sampleRateList="";
	my $prefSampleRates;
	
	my $prefs= getPreferences($client);

	if (!defined($prefs->client($client)->get('sampleRates'))){
	
		$prefSampleRates = _defaultSampleRates($client);
	
	} else {
		
		$prefSampleRates = _refreshSampleRates($client);
	}

	$sampleRateList= _guessSampleRateList($maxSupportedSamplerate);

	$prefs->client($client)->set('sampleRates', $class->translateSampleRates($prefSampleRates));

	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug("New sampleRates: ".dump($prefSampleRates));
	}
	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug("New preferences: ".dump($prefs->client($client)->get('sampleRates')));
	}
	
	return ($sampleRateList);
}
sub _defaultSampleRates{
	my $client=shift;
	
	my $caps=getCapabilities();
	my $capSamplerates= $caps->{'samplerates'};
	
	my $maxSupportedSamplerate= $client->maxSupportedSamplerate();
	
	my $prefSampleRates =();

	for my $rate (keys %$capSamplerates){
		if ($capSamplerates->{$rate} <= $maxSupportedSamplerate){
			$prefSampleRates->{$rate} = 1;
		} else {
			$prefSampleRates->{$rate} = 0;
		}
	}

	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug("Default SampleRates: ".dump($prefSampleRates));
	}
	return $prefSampleRates;
}
sub _refreshSampleRates{
	my $client=shift;
	
	my $prefs= getPreferences($client);
	my $caps= getCapabilities();
	my $capSamplerates= $caps->{'samplerates'};

	my $maxSupportedSamplerate= $client->maxSupportedSamplerate();
	
	my $prefRef = $class->translateSampleRates($prefs->client($client)->get('sampleRates'));
	my $prefSampleRates =();

	for my $rate (keys %$prefRef){
	
		if (!exists $capSamplerates->{$rate}){
			next;
		}
		if ($capSamplerates->{$rate} <= $maxSupportedSamplerate){
			$prefSampleRates->{$rate} = $prefRef->{$rate};
		} else {
			$prefSampleRates->{$rate} = 0;
		}
	}
	for my $rate (keys %$capSamplerates){
		
		# rate is new added in supported
		if (!exists $prefSampleRates->{$rate}){
				$prefSampleRates->{$rate}=undef;
		} 
	}
	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug("Refreshed SampleRates: ".dump($prefSampleRates));
	}
	return $prefSampleRates
}

sub _guessSampleRateList{
	my $maxrate=shift || 44100;

	# $client only reports the max sample rate of the player, 
	# we here assume that ANY lower sample rate in the player 
	# pcm_sample_rates table is valid.
	#
	
	my $sampleRateList="";
	
	for my $k (sort(keys %OrderedsampleRates)){
		my $rate=$OrderedsampleRates{$k};
		
		if ($rate+1 > $maxrate+1) {next};
		
		if (length($sampleRateList)>0) {
			$sampleRateList=$sampleRateList." "
		}
		$sampleRateList=$sampleRateList.$rate;
	}

	return $sampleRateList;
}

sub _initCodecs{
	my $client = shift;
	
	if ($client){
	
		return $class->initClientCodecs($client)
	}
	if (main::DEBUGLOG && $log->is_debug) {
		$log->debug('_initCodecs');	
	}
	my $prefs= getPreferences();
	my $codecList="";
	my $prefCodecs;
	
	if (!defined($prefs->get('codecs'))){
	
		$prefCodecs= _defaultCodecs();

	} else {
		
		$prefCodecs = _refreshCodecs();
	}
	#build the complete list string
	for my $codec (keys %$prefCodecs){

		if (length($codecList)>0) {

			$codecList=$codecList." ";
		}
		$codecList=$codecList.$codec;
	}
	$prefs->set('codecs', $prefCodecs);
	return ($codecList);
}

sub _defaultCodecs{
	
	if (main::DEBUGLOG && $log->is_debug) {
		$log->debug('_defaultCodecs');	
	}
	
	my $caps=getCapabilities();
	my $codecs= $caps->{'codecs'};
	
	my $prefCodecs =();

	my $supported=();

	#add all the codecs supported by C-3PO.
	for my $codec (keys %$codecs) {
		$supported->{$codec} = $codecs->{$codec}->{'supported'};
	}
	#set default enabled and remove unlisted.
	for my $codec (keys %$supported){
		
		if (exists $codecs->{$codec}->{'unlisted'}){ next;}
		
		$prefCodecs->{$codec}=undef;
		
		if (exists $codecs->{$codec}->{'supported'}){

			$prefCodecs->{$codec}=$codecs->{$codec}->{'supported'} ? "on" :undef;;
		}	
	}
	
	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug("Default codecs  : ".dump($prefCodecs));
	}
	return ($prefCodecs);
}
sub _defaultClientCodecs{
	my $client=shift;
	
	if (main::DEBUGLOG && $log->is_debug) {
		$log->debug('_defaultClientCodecs');	
	}

	my $C3POprefs	= getPreferences();
	my $codecs		= $C3POprefs->get('codecs');
	
	my $capabilities=getCapabilities();
	my $caps= $capabilities->{'codecs'};
	
	my $prefCodecs =();
	my $prefEnableSeek =();
	my $prefEnableStdin =();
	my $prefEnableConvert =();
	my $prefEnableResample =();
	
	my $supported=();
	
	#add all the codecs supported by the client.
	for my $codec (Slim::Player::CapabilitiesHelper::supportedFormats($client)) {
		$supported->{$codec} = 0;
		
	}
	#add all the codecs supported by C-3PO.
	for my $codec (keys %$codecs) {
		$supported->{$codec} = $codecs->{$codec};
	}
	#set default enabled
	for my $codec (keys %$supported){
		
		if ($caps->{$codec}->{'unlisted'}){ next;}
		
		$prefCodecs->{$codec}=undef;
		$prefEnableSeek->{$codec}=undef;
		$prefEnableStdin->{$codec}=undef;
		$prefEnableConvert->{$codec}=undef;
		$prefEnableResample->{$codec}=undef;
		
		if ($supported->{$codec}){

			$prefCodecs->{$codec}="on";
			$prefEnableConvert->{$codec}="on";
			$prefEnableResample->{$codec}="on";

			if ($caps->{$codec}->{'defaultEnableSeek'}){

				$prefEnableSeek->{$codec}="on";
			}
			if ($caps->{$codec}->{'defaultEnableStdin'}){

				$prefEnableStdin->{$codec}="on";
			}
		}	
	}
	
	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug("Default codecs  : ".dump($prefCodecs));
			 $log->debug("Enable Seek for : ".dump($prefEnableSeek));
			 $log->debug("Enable Stdin for : ".dump($prefEnableStdin));
			 $log->debug("Enable Convert for : ".dump($prefEnableConvert));
			 $log->debug("Enable Resample for : ".dump($prefEnableResample));
	}
	return ($prefCodecs, $prefEnableSeek, $prefEnableStdin,
	        $prefEnableConvert,$prefEnableResample);
}
sub _refreshCodecs{
	
	if (main::DEBUGLOG && $log->is_debug) {
		$log->debug('_refreshCodecs');	
	}
	
	my $prefs= getPreferences();

	my $prefRef = $prefs->get('codecs');
	
	my $caps=getCapabilities();
	my $codecs= $caps->{'codecs'};
	
	my $prefCodecs =();
	my $supported=();

	#add all the codecs supported by C-3PO.
	for my $codec (keys %$codecs) {
		$supported->{$codec} = $codecs->{$codec}->{'supported'};
	}
	#remove unlisted and unsupported.
	for my $codec (keys %$prefRef){

		if (exists $codecs->{$codec}->{'unlisted'}){
			next;
		}
		
		$prefCodecs->{$codec}=undef;
		
		if ($codecs->{$codec}->{'supported'}){

			$prefCodecs->{$codec}=$prefRef->{$codec};
		}
	}
	for my $codec (keys %$supported){

		if (exists $codecs->{$codec}->{'supported'}){

			# codec is new added in supported
			if (!exists $prefCodecs->{$codec}){
			
				$prefCodecs->{$codec}=undef;
			}
		} 
	}
	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug("Refreshed codecs       : ".dump($prefCodecs)); 
	}
	return ($prefCodecs);
}
sub _refreshClientCodecs{
	my $client=shift;
	
	if (main::DEBUGLOG && $log->is_debug) {
		$log->debug('_refreshClientCodecs');	
	}
	
	my $prefs= getPreferences($client);

	my $prefRef = $prefs->client($client)->get('codecs');
	my $prefEnableSeekRef = $prefs->client($client)->get('enableSeek');
	my $prefEnableStdinRef = $prefs->client($client)->get('enableStdin');
	my $prefEnableConvertRef = $prefs->client($client)->get('enableConvert');
	my $prefEnableResampleRef = $prefs->client($client)->get('enableResample');
	
	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug("codecs           : ".dump($prefRef));
			 $log->debug("seek enabled     : ".dump($prefEnableSeekRef));
			 $log->debug("stdin enabled    : ".dump($prefEnableStdinRef));
			 $log->debug("convert enabled  : ".dump($prefEnableConvertRef));
			 $log->debug("resample enabled : ".dump($prefEnableResampleRef));			 
	}
	
	my $capabilities=getCapabilities();
	my $caps= $capabilities->{'codecs'};
	
	my $C3POprefs	= getPreferences();
	my $codecs		= $C3POprefs->get('codecs');
	
	my $prefCodecs =();
	my $prefEnableSeek=();
	my $prefEnableStdin=();
	my $prefEnableConvert =();
	my $prefEnableResample =();
	
	my $supported=();
	
	#add all the codecs supported by the client.
	for my $codec (Slim::Player::CapabilitiesHelper::supportedFormats($client)) {
		$supported->{$codec} = 0;
	}
	#add all the codecs supported by C-3PO.
	for my $codec (keys %$codecs) {
		$supported->{$codec} = $codecs->{$codec};
	}
	#remove unlisted and unsupported.
	for my $codec (keys %$prefRef){

		if ($caps->{$codec}->{'unlisted'}){
			next;
		}

		if ($prefRef->{$codec} && $codecs->{$codec}){

			$prefCodecs->{$codec}=$prefRef->{$codec};
			$prefEnableSeek->{$codec}=$prefEnableSeekRef->{$codec};
			$prefEnableStdin->{$codec}=$prefEnableStdinRef->{$codec};
			$prefEnableConvert->{$codec}=$prefEnableConvertRef->{$codec};
			$prefEnableResample->{$codec}=$prefEnableResampleRef->{$codec};
		
		} elsif ($codecs->{$codec}){
		
			# codec was suported but disabled for player.
			$prefCodecs->{$codec}="on";
			$prefEnableConvert->{$codec}="on";
			$prefEnableResample->{$codec}="on";
			
			
			if ($caps->{$codec}->{'defaultEnableSeek'}){

				$prefEnableSeek->{$codec}="on";
			} else{
				$prefEnableSeek->{$codec}=undef;
			}
			if ($caps->{$codec}->{'defaultEnableStdin'}){

				$prefEnableStdin->{$codec}="on";
			} else {
				$prefEnableStdin->{$codec}=undef;	
			}
		} else {
			
			# codec is supported by the player but not C-3PO.
			$prefCodecs->{$codec}=undef;
			$prefEnableSeek->{$codec}=undef;
			$prefEnableStdin->{$codec}=undef;
			$prefEnableConvert->{$codec}=undef;
			$prefEnableResample->{$codec}=undef;
		}
	}
	for my $codec (keys %$supported){

		if ($caps->{$codec}->{'unlisted'}){
			next;
		}
		
		if ($codecs->{$codec}){

			# codec is new added in supported
			if (!exists $prefCodecs->{$codec}){
			
				$prefCodecs->{$codec}="on";
				$prefEnableConvert->{$codec}="on";
				$prefEnableResample->{$codec}="on";

				if ($caps->{$codec}->{'defaultEnableSeek'}){

					$prefEnableSeek->{$codec}="on";
				} else{
					$prefEnableSeek->{$codec}=undef;
				}
				if ($caps->{$codec}->{'defaultEnableStdin'}){

					$prefEnableStdin->{$codec}="on";
				} else {
					$prefEnableStdin->{$codec}=undef;	
				}
			}
		} else{
			
			# codec is supported by the player but not C-3PO.
			$prefCodecs->{$codec}=undef;
			$prefEnableSeek->{$codec}=undef;
			$prefEnableStdin->{$codec}=undef;
			$prefEnableConvert->{$codec}=undef;
			$prefEnableResample->{$codec}=undef;
		}
	}
	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug("Refreshed codecs       : ".dump($prefCodecs));
			 $log->debug("Refreshed seek enabled : ".dump($prefEnableSeek));
			 $log->debug("Refreshed stdin enabled: ".dump($prefEnableStdin));
			 $log->debug("Refreshed Convert enabled : ".dump($prefEnableConvert));
			 $log->debug("Refreshed Resample enable : ".dump($prefEnableResample));			 
	}
	return ($prefCodecs,$prefEnableSeek, $prefEnableStdin,
	        $prefEnableConvert,$prefEnableResample);
}
sub _playerSettingChanged{
	my $client = shift;
	
	#refresh preferences.
	refreshClientPreferences($client);
				
	#refresh the codec list.
	$class->initClientCodecs($client);

	#refresh transcoderTable.
	_setupTranscoder($client);
}
sub _disableProfiles{
	
	my %codecs=();
	
	my %newCodecs = %{getPreferences()->get('codecs')};
	
	if (main::DEBUGLOG && $log->is_debug) {		
		$log->debug("New codecs: ");
		$log->debug(dump(%newCodecs));
		$log->debug("previous codecs: ");
		$log->debug(dump(%previousCodecs));
		$log->debug("codecs: ");
		$log->debug(dump(%codecs));
	}
	
	for my $c (keys %previousCodecs){
	
		if ($previousCodecs{$c}) {$codecs{$c}=1;}
	}
	for my $c (keys %newCodecs){
		
		if ($newCodecs{$c}) {$codecs{$c}=1;}
	}
	
	if (main::DEBUGLOG && $log->is_debug) {		
		$log->debug("codecs: ");
		$log->debug(dump(%codecs));
	}
	
	my $conv = Slim::Player::TranscodingHelper::Conversions();
	
	if (main::DEBUGLOG && $log->is_debug) {		
		$log->debug("transcodeTable: ".dump($conv));
	}
	for my $profile (keys %$conv){
		
		#flc-pcm-*-00:04:20:12:b3:17
		#aac-aac-*-*
		
		my ($inputtype, $outputtype, $clienttype, $clientid) = _inspectProfile($profile);
		
		if ($codecs{$inputtype}){
		
			if (main::DEBUGLOG && $log->is_debug) {		
				$log->debug("disable: ". $profile);
			}
			
			_disableProfile($profile);
			
			my @clientList= Slim::Player::Client::clients();
	
			for my $client (@clientList){
			
				if (main::DEBUGLOG && $log->is_debug) {			
					$log->debug("clientid: ".$clientid);
					$log->debug("client-Id: ".$client->id());
				}
				if ($clientid && ($clientid eq $client->id())){
				
					if (main::DEBUGLOG && $log->is_debug) {	
						my $conv = Slim::Player::TranscodingHelper::Conversions();
						$log->debug("transcodeTable: ".dump($conv));
					}
					
					delete $Slim::Player::TranscodingHelper::commandTable{ $profile };
					delete $Slim::Player::TranscodingHelper::capabilities{ $profile };
					
					
					if (main::DEBUGLOG && $log->is_debug) {		
						my $conv = Slim::Player::TranscodingHelper::Conversions();
						$log->debug("transcodeTable: ".dump($conv));
					}
				}
			}

		}
	}
	%previousCodecs	= %newCodecs;
}
sub _inspectProfile{
	my $profile=shift;
	
	my $inputtype;
	my $outputtype;
	my $clienttype;
	my $clientid;;
	
	if ($profile =~ /^(\S+)\-+(\S+)\-+(\S+)\-+(\S+)$/) {

		$inputtype  = $1;
		$outputtype = $2;
		$clienttype = $3;
		$clientid   = lc($4);
		
		return ($inputtype, $outputtype, $clienttype, $clientid);	
	}
	return (undef,undef,undef,undef);
}
sub _enableProfile{
	my $profile = shift;
	my @out = ();
	
	my @disabled = @{ $serverPreferences->get('disabledformats') };
	for my $format (@disabled) {

		if ($format eq $profile) {next;}
		push @out, $format;
	}
	$serverPreferences->set('disabledformats', \@out);
	$serverPreferences->writeAll();
	$serverPreferences->savenow();
}
sub _disableProfile{
	my $profile = shift;
	my @disabled = @{ $serverPreferences->get('disabledformats') };
	my $found=0;
	for my $format (@disabled) {
		
		if ($format eq $profile){
			$found=1;
			last;}
	}
	if (! $found ){
		push @disabled, $profile;
		$serverPreferences->set('disabledformats', \@disabled);
		$serverPreferences->writeAll();
		$serverPreferences->savenow();
	}
}
sub _setupTranscoder{
	my $client=shift;
	
	my $transcodeTable=_buildTranscoderTable($client);
	
	if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug("TranscoderTable:");
			 $log->debug(dump($transcodeTable));
	}
	my %logger=();
		$logger{'DEBUGLOG'}=main::DEBUGLOG;
		$logger{'INFOLOG'}=main::INFOLOG;
		$logger{'log'}=$log;
	
	my $commandTable=Plugins::C3PO::Transcoder::initTranscoder($transcodeTable,\%logger);
	
	if (main::INFOLOG && $log->is_info) {
		$log->info("commandTable: ".dump($commandTable));
	}

	for my $profile (keys %$commandTable){

		my $cmd = $commandTable->{$profile};
		
		if (main::DEBUGLOG && $log->is_debug) {
			 $log->debug("\n".
						"PROFILE  : ".$cmd->{'profile'}."\n".
						" Command : ".$cmd->{'command'}."\n".
						" Capabilities: ".
						dump($cmd->{'capabilities'}));
		}
		_enableProfile($profile);
		$Slim::Player::TranscodingHelper::commandTable{ $cmd->{'profile'} } = $cmd->{'command'};
		$Slim::Player::TranscodingHelper::capabilities{ $cmd->{'profile'} } = $cmd->{'capabilities'};
	} 
}
sub _buildTranscoderTable{
	my $client=shift;
	
	#make sure codecs are up to date for the client:
	my $clientCodecList=$class->initClientCodecs($client);
	
	my $prefs= getPreferences($client);
	
	my $transcoderTable= Plugins::C3PO::Shared::getTranscoderTableFromPreferences($prefs,$client);
	
	#add the path to the preference file itself.
	#$transcoderTable->{'pathToPrefFile'}=$pathToPrefFile;
	
	return $transcoderTable;
}
sub _calcStatus{
	
	# Error/Warning/Info conditions, see Strings for descrptions.

	my $status;
	my $message;
	my %statusTab=();
	my $ref= \%statusTab;
	
	my $prefs= getPreferences();
	
	if (!$C3POwillStart && !$C3POisDownloading){
		
		$ref = _getStatusLine('001','all',$ref);

	}elsif ($C3POwillStart && $C3POwillStart eq 'pl' && !$C3POisDownloading){
		
		$ref = _getStatusLine('101','all',$ref);

	}elsif ($C3POwillStart && $C3POwillStart eq 'pl' && $C3POisDownloading){
		
		$ref = _getStatusLine('701','all',$ref);

	}elsif (!$C3POwillStart){ #Downloading
		
		$ref = _getStatusLine('601','all',$ref);

	}

	if (!$pathToFaad){
		
		$ref = _getStatusLine('014','all',$ref);

	}
	if (!$pathToFlac){
		
		$ref = _getStatusLine('013','all',$ref);

	}
	if (!$pathToSox){
		
		$ref = _getStatusLine('012','all',$ref);

	}
	if (($prefs->get('extra_before_rate') && !($prefs->get('extra_before_rate') eq "") ) ||
		($prefs->get('extra_after_rate') && !($prefs->get('extra_after_rate') eq "") )) {
		
		$ref = _getStatusLine('905','all',$ref);

	}
	my @clientList= Slim::Player::Client::clients();

	for my $client (@clientList){
		
		if (main::DEBUGLOG && $log->is_debug) {
			
			$log->debug("Id         ".$client->id());
			$log->debug("name       ".$client->name());
			$log->debug("model name ".$client->modelName());
			$log->debug("model      ".$client->model());
			$log->debug("firmware   ".$client->revision());
			
		}
		if (($client->model() eq 'squeezelite') && !($client->modelName() eq 'SqueezeLite-R2')){

			my $firmware = $client->revision();
			
			if (index(lc($firmware),'daphile') != -1) {

				$ref = _getStatusLine('921',$client,$ref);

			} else {
				
				$ref = _getStatusLine('021','server',$ref);
				$ref = _getStatusLine('021',$client,$ref);

			}
			
		} elsif (! ($client->model() eq 'squeezelite')) {

				$ref = _getStatusLine('521',$client,$ref);

		}
		
		$prefs= getPreferences($client);
		
		my $prefEnableSeekRef		= $prefs->client($client)->get('enableSeek');
		my $prefEnableStdinRef		= $prefs->client($client)->get('enableStdin');
		my $prefEnableConvertRef	= $prefs->client($client)->get('enableConvert');
		my $prefEnableResampleRef	= $prefs->client($client)->get('enableResample');
		
		for my $codec (keys %$prefEnableSeekRef){
			
			if ($prefEnableStdinRef->{$codec} && 
			    main::ISWINDOWS &&
				(($prefs->get('resampleWhen')eq 'E') ||
				 ($prefs->get('resampleTo') eq 'S'))) {
				
				if (main::DEBUGLOG && $log->is_debug) {	
					$log->debug("Player: ".$client->name());
					$log->debug("codec: ".$codec);
					$log->debug("Stdin: ".$prefEnableStdinRef->{$codec});
					$log->debug("ISWINDOWS: ".main::ISWINDOWS);
					$log->debug("resampleWhen: ".$prefs->get('resampleWhen'));
					$log->debug("resampleTo: ".$prefs->get('resampleTo'));
				}
				
				$ref = _getStatusLine('502','server',$ref);
				$ref = _getStatusLine('502',$client,$ref);

			}
			if ($prefEnableSeekRef->{$codec} && $prefEnableStdinRef->{$codec}){
				
				$ref = _getStatusLine('503','server',$ref);
				$ref = _getStatusLine('503',$client,$ref);

			}
			if ($prefEnableSeekRef->{$codec} && $prefEnableStdinRef->{$codec}){
				
				$ref = _getStatusLine('503','server',$ref);
				$ref = _getStatusLine('503',$client,$ref);

			}
			if ($prefEnableResampleRef->{$codec} && !$prefEnableConvertRef->{$codec}){
			
				if ($codec eq 'alc'){
					$ref = _getStatusLine('504',$client,$ref);
				} elsif ($codec eq 'flc'){
					$ref = _getStatusLine('904',$client,$ref);
				}
			}
		}
	}
	return \%statusTab;
}
sub _getStatusLine{
	my $code=shift;
	my $dest= shift;
	my $tab=shift;

	my $status = ($code < 500 ? "PLUGIN_C3PO_STATUS_ERROR" : 
				  $code < 900 ? "PLUGIN_C3PO_STATUS_WARNING" : 
							    "PLUGIN_C3PO_STATUS_INFO");
	
	$tab->{$dest}->{$code}->{'status'}=$status;
	
	my $base= 'PLUGIN_C3PO_STATUS_';

	if ($dest eq 'server') { 
		$tab->{$dest}->{$code}->{'message'}=$base.'SERVER_'.$code;
		
	} elsif ($dest eq 'all') { 
		$tab->{$dest}->{$code}->{'message'}=$base.$code;

	} else{
		$tab->{$dest}->{$code}->{'message'}=$base.'CLIENT_'.$code;
	};
	
	return $tab;
}
1;
