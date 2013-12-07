/*-------------------------------------------------------------------------------
* sdracq.c : SDR acquisition functions
*
* Copyright (C) 2013 Taro Suzuki <gnsssdrlib@gmail.com>
*------------------------------------------------------------------------------*/
import sdr;
import sdrcmn;
import util.trace;
import sdrrcv;
import sdrmain;

import std.math;
import std.stdio;

import std.algorithm;
import std.range;
import std.conv;
import std.datetime;
import std.random;


/* sdr acquisition function -----------------------------------------------------
* sdr acquisition function called from sdr channel thread
* args   : sdrch_t *sdr     I/O sdr channel struct
*          double *power    O   normalized correlation power vector (2D array)
* return : uint64_t             current buffer location
*------------------------------------------------------------------------------*/
size_t sdracquisition(string file = __FILE__, size_t line = __LINE__)(sdrch_t* sdr, double* power, size_t buffloc)
{
    traceln("called");

    // FFTを使った、正確なコード位相と、曖昧な搬送波周波数(ドップラー周波数)の探索
    {
        /* memory allocation */
        scope data = new byte[sdr.acq.nfft * sdr.dtype];

        /* acquisition integration */
        debug(AcqDebug){
            writefln("%s", sdr.acq.freq[0 .. sdr.acq.nfreq]);
            writefln("sdr.ftype: %s", sdr.ftype);
            writefln("sdr.dtype: %s", sdr.dtype);
            writefln("sdr.acq.nfft: %s", sdr.acq.nfft);
        }

        foreach(i; 0 .. sdr.acq.intg){

            /* get new 1ms data */
            rcvgetbuff(&sdrini, buffloc, sdr.acq.nfft, sdr.ftype, sdr.dtype, data);
            //buffloc += sdr.acq.nfft;
            //buffloc += (sdr.nsamp - sdr.acq.nfft % sdr.nsamp) % sdr.acq.nfft;
            buffloc += (cast(size_t)((cast(real)sdr.acq.nfft)/sdr.nsamp + 1)) * sdr.nsamp;

            /* fft correlation */
            pcorrelator(data, sdr.dtype, sdr.ti, sdr.acq.nfft, sdr.acq.freq, sdr.acq.nfreq, sdr.crate, sdr.acq.nfft, sdr.xcode, power);

            /* check acquisition result */
            if (checkacquisition(power, sdr)) {
                sdr.flagacq = true;
                break;
            }
        }
    }

    /* FFTを使った、それなりに正確な搬送波周波数(ドップラー周波数)の探索, L2CMの場合は前段の周波数探索で十分に正確に探索しているため不要 */
    if (sdr.flagacq && !(sdr.ctype == CType.L2RCCM)){
        scope datal = new byte[sdr.acq.nfft * sdr.dtype * sdr.acq.lenf];

        buffloc += sdr.acq.acqcodei; /* set buffer location at top of code */
        rcvgetbuff(&sdrini,buffloc, sdr.nsamp * sdr.acq.lenf, sdr.ftype, sdr.dtype, datal);

        /* fine doppler search */
        sdr.acq.acqfreqf = carrfsearch(datal, sdr.dtype, sdr.ti, sdr.crate, sdr.nsamp * sdr.acq.lenf, sdr.acq.nfftf, sdr.lcode[0 .. sdr.clen * sdr.acq.lenf]);
        writefln("%s, C/N0=%.1f, peak=%.1f, codei=%d, freq=%.1f, freqf=%.1f, diff=%.1f", sdr.satstr, sdr.acq.cn0, sdr.acq.peakr, cast(int)sdr.acq.acqcodei, sdr.acq.acqfreq - sdr.f_if, sdr.acq.acqfreqf - sdr.f_if, sdr.acq.acqfreq - sdr.acq.acqfreqf);
        
        sdr.trk.carrfreq = sdr.acq.acqfreqf;
        sdr.trk.codefreq = sdr.crate;

        /* check fine acquisition result */
        if (std.math.abs(sdr.acq.acqfreqf - sdr.acq.acqfreq) > sdr.acq.step)
            sdr.flagacq = false; /* reset */
    }else if(sdr.flagacq && sdr.ctype == CType.L2RCCM){
        buffloc += sdr.acq.acqcodei;    // バッファの先頭にコードの先頭が来るようにする
        sdr.acq.acqfreqf = sdr.acq.acqfreq;     // fineサーチしてないけど、してるように見せかけ
        sdr.trk.carrfreq = sdr.acq.acqfreq;
        sdr.trk.codefreq = sdr.crate;
        writefln("%s, C/N0=%.1f, peak=%.1f, codei=%d, freq=%.1f", sdr.satstr,sdr.acq.cn0,sdr.acq.peakr,sdr.acq.acqcodei,sdr.acq.acqfreq-sdr.f_if);
    }else
        writefln("%s, C/N0=%.1f, peak=%.1f, codei=%d, freq=%.1f", sdr.satstr,sdr.acq.cn0,sdr.acq.peakr,sdr.acq.acqcodei,sdr.acq.acqfreq-sdr.f_if);


    if(!sdr.flagacq)
        buffloc += uniform(0, sdr.nsamp >> 4);

    return buffloc;
}


/* check acquisition result -----------------------------------------------------
* check GNSS signal exists or not
* carrier frequency is computed
* args   : sdrch_t *sdr     I/0 sdr channel struct
*          double *P        I   normalized correlation power vector
* return : int                  acquisition flag (0: not acquired, 1: acquired) 
* note : first/second peak ratio and c/n0 computation
*------------------------------------------------------------------------------*/
bool checkacquisition(string file = __FILE__, size_t line = __LINE__)(double* P, sdrch_t* sdr)
{
    traceln("called");
    int maxi, codei, freqi;
    
    //immutable maxP = maxvd(P, sdr.acq.nfft * sdr.acq.nfreq, -1, -1, &maxi);
    //ind2sub(maxi, sdr.acq.nfft, sdr.acq.nfreq, &codei, &freqi);
    
    double maxP = 0.0;
    foreach(i; 0 .. sdr.acq.nfreq){
        int tmpi = void;
        auto tmpP = maxvd(&P[i * sdr.acq.nfft], sdr.nsamp, -1, -1, &tmpi);

        if(tmpP > maxP){
            maxP = tmpP;
            freqi = i;
            codei = tmpi;
        }
    }

    int submaxi = void;
    //ind2sub(maxi, sdr.acq.nfft, sdr.acq.nfreq, &codei, &freqi);
    immutable exinds = (a => (a < 0) ? (a + sdr.nsamp) : a)(codei - 4 * sdr.nsampchip),
              exinde = (a => (a >= sdr.nsamp) ? (a - sdr.nsamp) : a)(codei + 4 * sdr.nsampchip),
              meanP = meanvd(&P[freqi*sdr.acq.nfft], sdr.nsamp, exinds, exinde),
              maxP2 = maxvd(&P[freqi*sdr.acq.nfft], sdr.nsamp, exinds, exinde, &submaxi);

    //if(sdr.ctype == CType.L2RCCM){
    {
        static size_t n = 0;
        
        auto temp = P[freqi * sdr.acq.nfft .. (freqi + 1) * sdr.acq.nfft].zip(iota(size_t.max)).array().dup;
        temp.sort!"a[0] > b[0]"();
        ++n;
        auto f = File("result_" ~ sdr.ctype.to!string ~ "_" ~ n.to!string() ~ "_" ~ Clock.currTime.toISOString() ~ ".csv", "w");

        foreach(e; temp[0 .. 1024].sort!"a[1] < b[1]"())
            f.writefln("%s, %s,", e[1], e[0]);

        writefln("maxi = %s, submaxi = %s", maxi, submaxi);
        //assert(0);
    }
    //}


    sdr.ctype == CType.L2RCCM && writefln("codei = %s, %s[%s, %s]%s", codei, sdr.nsamp, exinds, exinde, sdr.acq.nfft);
    debug(AcqDebug) writefln("exind: [%s, %s]", exinds, exinde);

    /* C/N0 calculation */
    sdr.acq.cn0 = 10 * log10(maxP / meanP / sdr.ctime);

    /* peak ratio */
    sdr.acq.peakr = maxP / maxP2;
    sdr.acq.acqcodei = codei;
    sdr.acq.acqfreq = sdr.acq.freq[freqi];

    return sdr.acq.peakr > Constant.get!"Acquisition.TH"(sdr.ctype);
}


/* parallel correlator ----------------------------------------------------------
* fft based parallel correlator
* args   : char   *data     I   sampling data vector (n x 1 or 2n x 1)
*          DType  dtype     I   sampling data type (1:real,2:complex)
*          double ti        I   sampling interval (s)
*          int    n         I   number of samples
*          double *freq     I   doppler search frequencies (Hz)
*          int    nfreq     I   number of frequencies
*          double crate     I   code chip rate (chip/s)
*          int    m         I   number of resampling data
*          cpx_t  codex     I   frequency domain code
*          double *P        O   normalized correlation power vector
* return : none
* notes  : P=abs(ifft(conj(fft(code)).*fft(data.*e^(2*pi*freq*t*i)))).^2
*------------------------------------------------------------------------------*/
void pcorrelator(string file = __FILE__, size_t line = __LINE__)(in byte[] data, DType dtype, double ti, int n, in double[] freq,
                        int nfreq, double crate, int m, in cpx_t[] codex, double* P)
{
    traceln("called");

    scope dataR = new byte[m*dtype],
          dataI = new short[m],
          dataQ = new short[m],
          datax = new cpx_t[m];

    /* zero padding */
    dataR[] = 0;
    dataR[0 .. n * dtype] = data[0 .. n * dtype];

    foreach(i; 0 .. nfreq){
        // このtracingの2行をなくすと、最適化コンパイル(-O)時に正常に動作しなくなる。
        // 外部のFFTWを使っているのが原因だと思われる。
        // コンパイラのバグなので、FFTWを使っている限りは自分では修正不可
        immutable tmp = tracing;
        scope(exit) tracing = tmp;

        /* mix local carrier */
        mixcarr(dataR, dtype, ti, m, freq[i], 0.0, dataI.ptr, dataQ.ptr);
        dataI.zip(dataQ).csvOutput("mix_carr_" ~ freq[i].to!string() ~ ".csv");


        /* to complex */
        cpxcpx(dataI.ptr, dataQ.ptr, CSCALE / m, m, datax.ptr);
    
        /* convolution */
        cpxconv(datax, codex, true, P[i*n .. (i+1)*n]);
    }
}


/* doppler fine search ----------------------------------------------------------
* doppler frequency search with FFT
* args   : char   *data     I   sampling data vector (n x 1 or 2n x 1)
*          int    dtype     I   sampling data type (1:real,2:complex)
*          double ti        I   sampling interval (s)
*          double crate     I   code chip rate (chip/s)
*          int    n         I   number of samples
*          int    m         I   number of FFT points
*          int    clen      I   number of code
*          short  *code     I   long code
* return : double               doppler frequency (Hz)
*------------------------------------------------------------------------------*/
double carrfsearch(string file = __FILE__, size_t line = __LINE__)(const(byte)[] data, DType dtype, double ti, double crate, int n, int m, in short[] code)
{
    traceln("called");

    scope rdataI = new byte[m],
          rdataQ = new byte[m],
          rcode = new short[m],
          rcodeI = new short[m],
          rcodeQ = new short[m],
          fftxc = new double[m],
          datax = new cpx_t[m];

    {
        auto sink = rcode;
        resamplingCode(code, 0, 0, ti * crate, n, sink);
    }

    final switch(dtype){
      case DType.I:       // real
        rdataI[0 .. n] = data[0 .. n];
        
        mulvcs(rdataI, rcode, rcodeI);
        cpxcpx(rcodeI, null, 1.0, datax);       // to frequency domain
        cpxpspec(datax, 0, fftxc);              // compute power spectrum

        int ind = void;
        maxvd(fftxc[0 .. m/2], -1, -1, ind);

        return (cast(double)ind) / (m * ti);

      case DType.IQ:      // complex
        foreach(i; 0 .. n){
            rdataI[i] = data[i*2];
            rdataQ[i] = data[i*2 + 1];
        }

        mulvcs(rdataI, rcode, rcodeI);
        mulvcs(rdataQ, rcode, rcodeQ);
        cpxcpx(rcodeI, rcodeQ, 1.0, datax);     // to frequency domain
        cpxpspec(datax, 0, fftxc);              // compute power spectrum

        int ind = void;
        maxvd(fftxc[m/2 .. $], -1, -1, ind);

        return (m / 2.0 - ind) / (m * ti);
    }
}