/*-------------------------------------------------------------------------------
* sdrinit.c : SDR initialize/cleanup functions
*
* Copyright (C) 2013 Taro Suzuki <gnsssdrlib@gmail.com>
*------------------------------------------------------------------------------*/
import sdr;
import util.trace;
import sdrmain;
import sdrcode;
import sdrcmn;
import sdrplot;

import core.sync.mutex;

import std.algorithm;
import std.array;
//import std.c.string;
//import std.c.stdlib : atoi, atof;
import std.exception;
import std.file;
import std.range;
import std.stdio;
import std.string;
import std.traits;
import std.typecons;
import std.typetuple;


string[] readLines(File file)
{
    string[] lns;

    foreach(line; file.byLine)
        lns ~= line.strip().dup;

    return lns;
}


string readIniValue(T : string)(string[] fileLines, string section, string key)
{
    immutable secStr = "[" ~ section ~ "]";

    fileLines = fileLines.find!(a => a.startsWith(secStr))(); // sectionを探す
    fileLines = fileLines.find!(a => a.startsWith(key))();    // keyを探す

    auto str = fileLines.front.find!(a => a == '=')().drop(1);
    return str.until!(a => a == ';')().array().to!string().strip();
}


string readIniValue(T : string)(string file, string section, string key)
{
    return readIniValue(file.readLines, section, key);
}


T readIniValue(T, Input)(Input fileOrLines, string section, string key)
if(!is(T == string))
{
    string value = fileOrLines.readIniValue!string(section, key);

    static if(isArray!T)
    {
        return ("[" ~ value ~ "]").to!(T)();
    }
    else if(isSomeString!T)
    {
        return value.to!T();
    }
    else
    {
        return value.to!T();
    }
}


/* read ini file ----------------------------------------------------------------
* read ini file and set value to sdrini struct
* args   : sdrini_t *ini    I/0 sdrini struct
* return : int                  0:okay -1:error
* note : this function is only used in CLI application
*------------------------------------------------------------------------------*/
void readIniFile(string file = __FILE__, size_t line = __LINE__)(ref sdrini_t ini, string iniFile)
{
    traceln("called");

    enforce(std.file.exists(iniFile), "error: gnss-sdrcli.ini doesn't exist");
    auto iniLines = File(iniFile).readLines;

    {
        ini.fend = iniLines.readIniValue!Fend("RCV", "FEND");

        if (ini.fend == Fend.FILE || ini.fend == Fend.FILESTEREO){
            ini.file1 = iniLines.readIniValue!string("RCV", "FILE1");
            if(ini.file1.length)
                ini.useif1 = true;
        }

        if (ini.fend == Fend.FILE) {
            ini.file2 = iniLines.readIniValue!string("RCV", "FILE2");
            if(ini.file2.length)
                ini.useif2 = true;
        }
    }
    
    {
        ini.f_sf[0] = iniLines.readIniValue!double("RCV", "SF1");
        ini.f_if[0] = iniLines.readIniValue!double("RCV", "IF1");
        ini.dtype[0] = iniLines.readIniValue!DType("RCV", "DTYPE1");
        ini.f_sf[1] = iniLines.readIniValue!double("RCV", "SF2");
        ini.f_if[1] = iniLines.readIniValue!double("RCV", "IF2");
        ini.dtype[1] = iniLines.readIniValue!DType("RCV", "DTYPE2");
        ini.confini = iniLines.readIniValue!int("RCV", "CONFINI");
    }
    
    ini.nch = iniLines.readIniValue!int("CHANNEL", "NCH").enforce("error: wrong inifile value NCH=%d".format(ini.nch));
    
    {
        T[] getChannelSpec(T)(string key)
        {
            T[] tmp;
            tmp = iniLines.readIniValue!(T[])("CHANNEL", key);
            enforce(tmp.length >= ini.nch);
            return tmp[0 .. ini.nch];
        }

        ini.sat   = getChannelSpec!int("SAT");
        ini.sys   = getChannelSpec!NavSystem("SYS");
        ini.ctype = getChannelSpec!CType("CTYPE");
        ini.ftype = getChannelSpec!FType("FTYPE");
    }
    
    {
        ini.pltacq = iniLines.readIniValue!bool("PLOT", "ACQ");
        ini.plttrk = iniLines.readIniValue!bool("PLOT", "TRK");

        ini.outms = iniLines.readIniValue!int("OUTPUT", "OUTMS");
        ini.rinex = iniLines.readIniValue!bool("OUTPUT", "RINEX");
        ini.rtcm = iniLines.readIniValue!bool("OUTPUT", "RTCM");
        ini.rinexpath = iniLines.readIniValue!string("OUTPUT", "RINEXPATH");
        ini.rtcmport = iniLines.readIniValue!ushort("OUTPUT", "RTCMPORT");
        ini.lexport = iniLines.readIniValue!ushort("OUTPUT", "LEXPORT");

        /* spectrum setting */
        ini.pltspec = iniLines.readIniValue!bool("SPECTRUM", "SPEC");
    }
    
    foreach(i; 0 .. sdrini.nch){
        if (sdrini.ctype[i] == CType.L1CA) {
            sdrini.nchL1++;
        }else if (sdrini.ctype[i] == CType.LEXS) {
            sdrini.nchL6++;
        }else if(sdrini.ctype[i] == CType.L2RCCM)
            sdrini.nchL2++;
        else
            enforce(0, "ctype: %s is not supported.".format(sdrini.ctype[i]));
    }
}


/* check initial value ----------------------------------------------------------
* checking value in sdrini struct
* args   : sdrini_t *ini    I   sdrini struct
* return : int                  0:okay -1:error
*------------------------------------------------------------------------------*/
void checkInitValue(string file = __FILE__, size_t line = __LINE__)(in ref sdrini_t ini)
{
    traceln("called");

    enforce(ini.f_sf[0] > 0 && ini.f_sf[0] < 100e6, "error: wrong freq. input sf1: %s".format(ini.f_sf[0]));
    enforce(ini.f_if[0] >= 0 && ini.f_if[0] < 100e6, "error: wrong freq. input if1: %s".format(ini.f_if[0]));

    enforce(ini.f_sf[1] > 0 && ini.f_sf[1] < 100e6, "error: wrong freq. input sf1: %s".format(ini.f_sf[1]));
    enforce(ini.f_if[1] >= 0 && ini.f_if[1] < 100e6, "error: wrong freq. input if1: %s".format(ini.f_if[1]));

    enforce(ini.rtcmport >= 0 && ini.rtcmport <= short.max, "error: wrong rtcm port rtcm:%s".format(ini.rtcmport));
    enforce(ini.lexport >= 0 && ini.lexport <= short.max, "error: wrong rtcm port lex:%d".format(ini.lexport));

    /* checking filepath */
    if(ini.fend == Fend.FILE || ini.fend == Fend.FILESTEREO){
        enforce(!ini.useif1 || exists(ini.file1), "error: file1 doesn't exist: %s".format(ini.file1));
        enforce(!ini.useif2 || exists(ini.file2), "error: file1 or file2 are not selected".format(ini.file2));
        enforce(ini.useif1 || ini.useif2, "error: file1 or file2 are not selected");
    }

    /* checking rinex directory */
    if (ini.rinex) 
        enforce(exists(ini.rinexpath), "error: rinex output directory doesn't exist: %s".format(ini.rinexpath));
}


/* initialization plot struct ---------------------------------------------------
* set value to plot struct
* args   : sdrplt_t *acq    I/0 plot struct for acquisition
*          sdrplt_t *trk    I/0 plot struct for tracking
*          sdrch_t  *sdr    I   sdr channel struct
* return : int                  0:okay -1:error
*------------------------------------------------------------------------------*/
void initpltstruct(string file = __FILE__, size_t line = __LINE__)(sdrplt_t *acq, sdrplt_t *trk, sdrch_t *sdr)
{
    traceln("called");

    /* acquisition */
    if (sdrini.pltacq) {
        setsdrplotprm(acq, PlotType.SurfZ, sdr.acq.nfreq, sdr.acq.nfft, sdr.nsampchip/3, Flag!"doAbs".no, 1, Constant.Plot.H, Constant.Plot.W, Constant.Plot.MH, Constant.Plot.MW, sdr.no);
        initsdrplot(acq);
        settitle(acq,sdr.satstr);
        setlabel(acq,"Frequency (Hz)","Code Offset (sample)");

        acq.otherSetting = "set size 0.8,0.8\n";

        acq.xvalue = sdr.acq.freq[0 .. sdr.acq.nfreq].dup;
        acq.yvalue = iota(sdr.acq.nfft).map!"cast(double)a"().array();
    }

    /* tracking */
    if (sdrini.plttrk) {
        setsdrplotprm(trk, PlotType.XY, 1 + 2 * sdr.trk.ncorrp, 0, 0, Flag!"doAbs".yes, 0.001, Constant.Plot.H, Constant.Plot.W, Constant.Plot.MH, Constant.Plot.MW, sdr.no);
        initsdrplot(trk);
        settitle(trk, sdr.satstr);
        setlabel(trk, "Code Offset (sample)", "Correlation Output");
        setyrange(trk, 0, 8 * sdr.trk.loopms);

        trk.otherSetting = "set size 0.8,0.8\n";
    }

    if (sdrini.fend == Fend.FILE||sdrini.fend == Fend.FILESTEREO)
        trk.pltms = Constant.Plot.MS_FILE;
    else
        trk.pltms = Constant.Plot.MS;
}


/* termination plot struct ------------------------------------------------------
* termination plot struct
* args   : sdrplt_t *acq    I/0 plot struct for acquisition
*          sdrplt_t *trk    I/0 plot struct for tracking
* return : none
*------------------------------------------------------------------------------*/
void quitpltstruct(string file = __FILE__, size_t line = __LINE__)(sdrplt_t *acq, sdrplt_t *trk)
{
    traceln("called");
    if (sdrini.pltacq)
        quitsdrplot(acq);
    
    if (sdrini.plttrk)
        quitsdrplot(trk);
}


/* initialize acquisition struct ------------------------------------------------
* set value to acquisition struct
* args   : int sys          I   system type (SYS_GPS...)
*          int ctype        I   code type (CType.L1CA...)
*          sdracq_t *acq    I/0 acquisition struct
* return : int                  0:okay -1:error
*------------------------------------------------------------------------------*/
void initacqstruct(string file = __FILE__, size_t line = __LINE__)(int sys, CType ctype, sdracq_t *acq)
{
    traceln("called");

    enum sourceCode = q{
        acq.intg = INTG;
        acq.hband = HBAND;
        acq.step = STEP;
        acq.nfreq = 2 * (HBAND / STEP) + 1;
        //acq.lenf = LENF;
    };

    switch(ctype){
      case CType.L1CA:
        with(Constant.L1CA.Acquisition){
            mixin(sourceCode);
            acq.lenf = LENF;
        }
        break;

      case CType.L1SAIF:
        with(Constant.L1SAIF.Acquisition){
            mixin(sourceCode);
            acq.lenf = LENF;
        }
        break;

      case CType.L2RCCM:
        with(Constant.L2C.Acquisition)
            mixin(sourceCode);
        break;

      default:
        enforce(0);
    }
}


/* initialize tracking parameter struct -----------------------------------------
* set value to tracking parameter struct
* args   : sdrtrkprm_t *prm I/0 tracking parameter struct
*          int    sw        I   tracking mode selector switch (1 or 2)
* return : int                  0:okay -1:error
*------------------------------------------------------------------------------*/
void inittrkprmstruct(string file = __FILE__, size_t line = __LINE__)(CType ctype, sdrtrkprm_t *prm, int sw)
{
    traceln("called");
    int trkcp, trkcdn;
    
    /* tracking parameter selection */
    switch(sw){
      case 1:
        prm.dllb = Constant.get!"Tracking.Parameter1.DLLB"(ctype);
        prm.pllb = Constant.get!"Tracking.Parameter1.PLLB"(ctype);
        prm.fllb = Constant.get!"Tracking.Parameter1.FLLB"(ctype);
        prm.dt   = Constant.get!"Tracking.Parameter1.DT"(ctype);
        trkcp    = Constant.get!"Tracking.Parameter1.CP"(ctype);
        trkcdn   = Constant.get!"Tracking.Parameter1.CDN"(ctype);
        break;

      case 2:
        prm.dllb = Constant.get!"Tracking.Parameter2.DLLB"(ctype);
        prm.pllb = Constant.get!"Tracking.Parameter2.PLLB"(ctype);
        prm.fllb = Constant.get!"Tracking.Parameter2.FLLB"(ctype);
        prm.dt   = Constant.get!"Tracking.Parameter2.DT"(ctype);
        trkcp    = Constant.get!"Tracking.Parameter2.CP"(ctype);
        trkcdn   = Constant.get!"Tracking.Parameter2.CDN"(ctype);
        break;

      default:
        assert(0, "error: inittrkprmstruct sw = %s".format(sw));
    }


    /* correlation point */
    //prm.corrp = cast(int*)malloc(int.sizeof * Constant.TRKCN).enforce();
    prm.corrp = (){
        auto dst = new size_t[Constant.TRKCN];
        foreach(i, ref e; dst){
            e = trkcdn * (i + 1);

            if (e == trkcp){
                prm.ne = (i + 1) * 2 - 1; /* Early */
                prm.nl = (i + 1) * 2;   /* Late */
            }
        }

        return dst.idup;
    }();


    /* correlation point for plot */
    //prm.corrx = cast(double*)calloc(Constant.TRKCN *2 + 1, double.sizeof).enforce();
    prm.corrx = (){
        auto dst = new double[Constant.TRKCN *2 + 1];
        foreach(i; 1 .. Constant.TRKCN){
            dst[i*2 - 1] = -trkcdn * i;
            dst[i*2    ] = +trkcdn * i;
        }

        return dst.idup;
    }();


    /* calculation loop filter parameters */
    {
        immutable dll_k = prm.dllb / 0.53,
                  pll_k = prm.pllb / 0.53;

        prm.dllw2 = dll_k ^^ 2;
        prm.dllaw = 1.414 * dll_k;
        prm.pllw2 = pll_k ^^ 2;
        prm.pllaw = 1.414 * pll_k;
        prm.fllw  = prm.fllb / 0.25;
    }
}


/* initialize tracking struct --------------------------------------------------
* set value to tracking struct
* args   : int sys          I   system type (SYS_GPS...)
*          int ctype        I   code type (CType.L1CA...)
*          sdrtrk_t *trk    I/0 tracking struct
* return : int                  0:okay -1:error
*------------------------------------------------------------------------------*/
void inittrkstruct(string file = __FILE__, size_t line = __LINE__)(int sys, CType ctype, sdrtrk_t *trk)
{
    traceln("called");

    inittrkprmstruct(ctype, &trk.prm1, 1);
    inittrkprmstruct(ctype, &trk.prm2, 2);

    trk.ncorrp = Constant.TRKCN;

    with(trk) foreach(e; TypeTuple!("I", "Q", "oldI", "oldQ", "sumI", "sumQ", "oldsumI", "oldsumQ")){
        mixin(e) = new double[1 + 2 * trk.ncorrp];
        mixin(e)[] = 0;
    }

    trk.loopms = Constant.get!"LOOP_MS"(ctype);
}


/* initialize navigation struct -------------------------------------------------
* set value to navigation struct
* args   : int sys          I   system type (SYS_GPS...)
*          int ctype        I   code type (CType.L1CA...)
*          sdrnav_t *nav    I/0 navigation struct
* return : int                  0:okay -1:error
*------------------------------------------------------------------------------*/
void initnavstruct(string file = __FILE__, size_t line = __LINE__)(int sys, CType ctype, sdrnav_t *nav)
{
    traceln("called");
    int[32] preamble = 0;
    int[] pre_l1ca = [1,-1,-1,-1,1,-1,1,1]; /* GPS L1CA preamble*/
    int[] pre_l1saif=[1,-1,1,-1,1,1,-1,-1]; /* QZSS L1SAIF preamble */
    version(none) int[2] poly = [V27POLYA,V27POLYB];

    nav.ctype = ctype;

    nav.bitth = Constant.get!"Navigation.BITTH"(ctype);
    nav.rate = Constant.get!"Navigation.RATE"(ctype);
    nav.flen = Constant.get!"Navigation.FLEN"(ctype);
    nav.addflen = Constant.get!"Navigation.ADDFLEN"(ctype);
    nav.addplen = Constant.get!"Navigation.ADDPLEN"(ctype);
    nav.prelen = Constant.get!"Navigation.PRELEN"(ctype);
    memcpy(preamble.ptr,pre_l1ca.ptr,int.sizeof*nav.prelen);

    nav.prebits =  cast(int*)malloc(int.sizeof*nav.prelen).enforce();
    scope(failure) free(nav.prebits);
    nav.bitsync= cast(int*)calloc(nav.rate,int.sizeof).enforce();
    scope(failure) free(nav.bitsync);
    nav.fbits=   cast(int*)calloc(nav.flen+nav.addflen,int.sizeof).enforce();
    scope(failure) free(nav.fbits);
    nav.fbitsdec=cast(int*)calloc(nav.flen+nav.addflen,int.sizeof).enforce();
    scope(failure) free(nav.fbitsdec);

    memcpy(nav.prebits,preamble.ptr,int.sizeof*nav.prelen);
}


/* initialize sdr channel struct ------------------------------------------------
* set value to sdr channel struct
* args   : int    chno      I   channel number (1,2,...)
*          int    sys       I   system type (SYS_***)
*          int    prn       I   PRN number
*          int    ctype     I   code type (CType.***)
*          int    dtype     I   data type (DTYPEI or DTYPEIQ)
*          int    ftype     I   front end type (FTYPE1 or FTYPE2)
*          double f_sf      I   sampling frequency (Hz)
*          double f_if      I   intermidiate frequency (Hz)
*          sdrch_t *sdr     I/0 sdr channel struct
* return : int                  0:okay -1:error
*------------------------------------------------------------------------------*/
int initsdrch(string file = __FILE__, size_t line = __LINE__)(uint chno, NavSystem sys, int prn, CType ctype, DType dtype, FType ftype, double f_sf, double f_if, sdrch_t *sdr)
{
    traceln("called");
    
    sdr.no      = chno;
    sdr.sys     = sys;
    sdr.prn     = prn;
    sdr.sat     = satno(sys, prn);
    sdr.ctype   = ctype;
    sdr.dtype   = dtype;
    sdr.ftype   = ftype;
    sdr.f_sf    = f_sf;
    sdr.f_if    = f_if;
    sdr.ti      = f_sf ^^ -1;


    /* code generation */
    sdr.code = (){
        auto ptr = gencode(prn,ctype, &sdr.clen, &sdr.crate);
        return ptr[0 .. sdr.clen].idup;
    }();

    sdr.ci        = sdr.ti*sdr.crate;
    sdr.ctime     = sdr.clen/sdr.crate;
    sdr.nsamp     = cast(int)(f_sf * sdr.ctime);
    sdr.nsampchip = cast(int)(sdr.nsamp / sdr.clen);
    sdr.satstr    = satno2Id(sdr.sat);

    /* acqisition struct */
    initacqstruct(sys, ctype, &sdr.acq);

    sdr.acq.nfft = cast(int)nextPow2(sdr.nsamp); //sdr.nsamp;           // PRNコード1周期分

    sdr.acq.nfftf = (){
        if(ctype == CType.L1CA)
            return calcfftnumreso(Constant.get!"Acquisition.FFTFRESO"(ctype), sdr.ti).to!int();
        else if(ctype == CType.L2RCCM)
            return -1;
        else
            enforce(0);

        assert(0);
    }();



    /* doppler search frequency */
    sdr.acq.freq = {
        auto dst = new double[sdr.acq.nfreq];

        if(ctype != CType.L2RCCM)
            foreach(i; 0 .. sdr.acq.nfreq)
                dst[i] = sdr.f_if + (i - (sdr.acq.nfreq-1) / 2) * sdr.acq.step;
        else{
            immutable carrierRatio = 60.0 / 77.0;   // = f_L2C / f_L1CA = 1227.60 MHz / 1575.42 MHz = (2 * 60 * 10.23MHz) / (2 * 77 * 10.23MHz)
            immutable inferenced = (sdrmain.l1ca_doppler - sdrini.f_if[0]) * carrierRatio + sdr.f_if;
            writefln("l1ca_doppler=%s, inferenced=%s,",sdrmain.l1ca_doppler, inferenced);

            foreach(i; 0 .. sdr.acq.nfreq)
                dst[i] = inferenced + (i - (sdr.acq.nfreq-1) / 2) * sdr.acq.step;
        }

        return dst.idup;
    }();


    /* tracking struct */
    inittrkstruct(sys, ctype, &sdr.trk);

    //if(ctype != CType.L2RCCM){
        /* navigation struct */
        initnavstruct(sys, ctype, &sdr.nav);
    if(ctype != CType.L2RCCM){
        ///* memory allocation */
        //sdr.lcode = cast(short*)malloc(short.sizeof * sdr.clen * sdr.acq.lenf).enforce();
        //scope(failure) free(sdr.lcode);

        //foreach(i; 0 .. sdr.clen * sdr.acq.lenf) /* long code for fine search */
        //    sdr.lcode[i] = sdr.code[i % sdr.clen];
        sdr.lcode = sdr.code.cycle.take(sdr.clen * sdr.acq.lenf).array.assumeUnique;
    }

    /* memory allocation */
    sdr.xcode = (){
        scope rcode = new short[sdr.acq.nfft];
        scope dst = new Complex!float[sdr.acq.nfft];

        /* other code generation */
        rcode[] = 0;       // zero padding
        rescode(sdr.code.ptr, sdr.clen, 0, 0, sdr.ci, sdr.acq.nfft, rcode); /* resampled code */
        cpxcpx(rcode, null, 1.0, dst); /* FFT code */
        cpxfft(dst);
        return dst.idup;
    }();
    
    return 0;
}


/* free sdr channel struct ------------------------------------------------------
* free memory in sdr channel struct
* args   : sdrch_t *sdr     I/0 sdr channel struct
* return : none 
*------------------------------------------------------------------------------*/
void freesdrch(string file = __FILE__, size_t line = __LINE__)(sdrch_t *sdr)
{
    traceln("called");
    //free(sdr.code);
    sdr.code = null;
    free(sdr.lcode);
    cpxfree(sdr.xcode);
    free(sdr.nav.prebits);
    free(sdr.nav.fbits);
    free(sdr.nav.fbitsdec);
    free(sdr.nav.bitsync);
    free(sdr.trk.I);
    free(sdr.trk.Q);
    free(sdr.trk.oldI);
    free(sdr.trk.oldQ);
    free(sdr.trk.sumI);
    free(sdr.trk.sumQ);
    free(sdr.trk.oldsumI);
    free(sdr.trk.oldsumQ);
    free(sdr.trk.prm1.corrp);
    free(sdr.trk.prm2.corrp);
    free(sdr.acq.freq);

    if (sdr.nav.fec !is null)
        delete_viterbi27_port(sdr.nav.fec);
}