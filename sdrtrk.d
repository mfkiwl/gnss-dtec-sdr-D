// Written in the D programming language.
/**
Authors: Kazuki Komatsu, Taro Suzuki <gnsssdrlib@gmail.com>
License: Kazuki Komatsu - NYSL, 
         Copyright (C) 2013 Taro Suzuki <gnsssdrlib@gmail.com>
*/
import core.simd;
import core.bitop;

import sdr;
import sdrrcv;
import sdrcmn;
import sdrnav;

import util.trace;
import util.numeric;
import util.range;

import std.math;
import std.stdio;
import std.traits;
import std.parallelism;
import std.exception;
import std.array;
import std.string;
import std.algorithm;
import std.range;
import std.typetuple;


private F atan(F)(F y, F x)
if(isFloatingPoint!F)
out(r){
    assert(r.isNaN || (-PI/2 <= r && r <= PI/2));
}
body{
    return x.signbit ? atan2(-y, -x) : atan2(y, x);
}


version(Actors)
{
    class LostSignal : Exception
    {
        this(string msg = "Lost signal",
             string file = __FILE__,
             size_t line = __LINE__)
        {
            super(msg, file, line);
        }
    }
}


/** 信号追尾ループ
 *
 */
void sdrtracking(Ch)(ref Ch ch, size_t cnt)
if(isSDRChannel!Ch)
in{
    assert(ch.sdr.clen.isValidNum);
    assert(ch.sdr.trk.remcode.isValidNum);
    assert(ch.sdr.trk.codefreq.isValidNum);
    assert(ch.sdr.f_sf.isValidNum);
}
body{
    scope sdr = &ch.sdr,
          reader = &ch.reader;

    traceln("called");

    immutable lenOf1ms = sdr.crate * 0.001,
              remcode1ms = (a => a < 1 ? a : (a - lenOf1ms))
                                    (sdr.trk.remcode % lenOf1ms),
              trkN = ((lenOf1ms - remcode1ms)
                        /(sdr.trk.codefreq/sdr.f_sf)).to!size_t();

    sdr.currnsamp = ((lenOf1ms - remcode1ms)
                   /(sdr.trk.codefreq/sdr.f_sf)
                   * (sdr.ctime / 0.001L)).to!int();

    traceln();

    immutable beforeBuffloc = reader.pos;

    // データ読み込み
    scope data = reader.copy(
        uninitializedArray!(byte[])(trkN * sdr.dtype));
    reader.consume(trkN);

    traceln();

    {
        traceln();
        immutable copySize = 1 + 2 * sdr.trk.ncorrp;
        sdr.trk.oldI[0 .. copySize] = sdr.trk.I[0 .. copySize];
        sdr.trk.oldQ[0 .. copySize] = sdr.trk.Q[0 .. copySize];
    }

    traceln();

    sdr.trk.oldremcode = sdr.trk.remcode;
    sdr.trk.oldremcarr = sdr.trk.remcarr;

    traceln();

    /* correlation */
    correlator(data, sdr.dtype, sdr.ti, trkN, sdr.trk.carrfreq,
               sdr.trk.oldremcarr, sdr.trk.codefreq, sdr.trk.oldremcode,
               sdr.trk.prm1.corrp, sdr.trk.ncorrp,
               sdr.trk.Q, sdr.trk.I, &sdr.trk.remcode,
               &sdr.trk.remcarr, sdr.code);
    
    traceln();

    /* navigation data */
    (*sdr).sdrnavigation(beforeBuffloc, cnt);
    sdr.flagtrk = true;

    // SNRが悪くなった場合にSDRが自殺を図る
    if((sdr.flagnavsync || cnt > 500) && sdr.trk.S[].find(0).empty)
    {
        immutable meanSNR = sdr.trk.S[].mean();
        // 追尾できなくなった(信号が途絶えた場合)
        if(meanSNR < Constant.get!"Tracking.snrThreshold"(sdr.ctype)){
          version(Actors)
          {
            enforceEx!LostSignal(0,
                "signal is interruptted. SNR: %s[dB]".format(meanSNR));
          }
          else
          {
            writefln("signal is interruptted. SNR: %s[dB]", meanSNR);
            sdr.reInitialize();
          }
        }
    }
    
    traceln();
}


/* correlator -------------------------------------------------------------------
* multiply sampling data and carrier (I/Q), multiply code (E/P/L), and integrate
* args   : char   *data     I   sampling data vector (n x 1 or 2n x 1)
*          int    dtype     I   sampling data type (1:real,2:complex)
*          double ti        I   sampling interval (s)
*          int    n         I   number of samples
*          double freq      I   carrier frequency (Hz)
*          double phi0      I   carrier initial phase (rad)
*          double crate     I   code chip rate (chip/s)
*          double coff      I   code chip offset (chip)
*          int    s         I   correlator points (sample)
*          short  *I,*Q     O   correlation power I,Q
*                                 I={I_P,I_E1,I_L1,I_E2,I_L2,...,I_Em,I_Lm}
*                                 Q={Q_P,Q_E1,Q_L1,Q_E2,Q_L2,...,Q_Em,Q_Lm}
* return : none
* notes  : see above for data
*------------------------------------------------------------------------------*/
void correlator(string file = __FILE__, size_t line = __LINE__)(const(byte)[] data, DType dtype, double ti, size_t n, double freq, double phi0, 
                       double crate, double coff, in size_t[] s, int ns, double[] I, double[] Q,
                       double *remc, double *remp, in short[] codein)
in{
    bool b0 = (ti.isValidNum),
         b1 = (freq.isValidNum),
         b2 = (phi0.isValidNum),
         b3 = (crate.isValidNum),
         b4 = (coff.isValidNum);

    scope(failure)
        traceln([b0, b1, b2, b3, b4]);

    assert(b0 && b1 && b2 && b3 && b4);
}
body{
    traceln("called");
    immutable smax = s[ns-1];

  version(Win32)
  {
    enum size_t VectorizedN = 8;
    alias ElemType = short[VectorizedN];
    enum sliceOp = "[]";
    enum getElem = "";
  }
  else
  {
    version(AVX)
    {
        enum size_t VectorizedN = 16;          // AVX(256bit -> short * 16)
    }
    else
    {
        enum size_t VectorizedN = 8;           // SSE(128bit -> short * 8)
    }

    alias ElemType = Vector!(short[VectorizedN]);
    enum sliceOp = "";
    enum getElem =".array";
  }

    immutable packedLength = (n + (VectorizedN-1)) / VectorizedN;
    scope dataI = uninitializedArray!(ElemType[])(packedLength),
          dataQ = uninitializedArray!(ElemType[])(packedLength),
          code_e = uninitializedArray!(ElemType[])(packedLength + 2*smax/VectorizedN);

    // あまりの部分の初期化
    dataI[$-1] = 0;
    dataQ[$-1] = 0;
    code_e[$-1] = 0;

    const code = code_e.ptr + smax / VectorizedN;

    /* mix local carrier */ // exp(-j2πft+φ)を乗算する
    *remp = mixcarr(data, dtype, ti, freq, phi0, (cast(short*)(dataI.ptr))[0 .. n], (cast(short*)(dataQ.ptr))[0 .. n]);

    /* resampling code */
    *remc = codein.resampling(coff, smax, ti*crate, n, (cast(short*)(code_e.ptr))[0 .. n + smax * 2]);

    // I[0] := IP, I[1] := IE, I[2] := IL, Q[0] := QP, Q[1] := QE, Q[2] := QL
    I[0] = I[1] = I[2] = Q[0] = Q[1] = Q[2] = 0;

    // Prompt, Early, LateとI-phase, Q-phaseのそれぞれの内積を計算するブロック
    {
        enum SubN = 32;     // accumulateする最大の数
                            // これが大きければ飽和するが、高速化につながる

        const(ElemType)* pI = dataI.ptr,                // I-phase
                         pQ = dataQ.ptr,                // Q-phase
                         pP = code,                     // Prompt
                         pE = (code-s[0]/VectorizedN),  // Early
                         pL = (code+s[0]/VectorizedN);  // Late

        enum statement = q{
            {
                ElemType sumIP, sumQP, sumIE, sumQE, sumIL, sumQL;

                foreach(j; 0 .. %s){
                    mixin(`sumIP` ~ sliceOp) += mixin(`(*pI)` ~ sliceOp) * mixin(`(*pP)` ~ sliceOp);
                    mixin(`sumQP` ~ sliceOp) += mixin(`(*pQ)` ~ sliceOp) * mixin(`(*pP)` ~ sliceOp);
                    mixin(`sumIE` ~ sliceOp) += mixin(`(*pI)` ~ sliceOp) * mixin(`(*pE)` ~ sliceOp);
                    mixin(`sumQE` ~ sliceOp) += mixin(`(*pQ)` ~ sliceOp) * mixin(`(*pE)` ~ sliceOp);
                    mixin(`sumIL` ~ sliceOp) += mixin(`(*pI)` ~ sliceOp) * mixin(`(*pL)` ~ sliceOp);
                    mixin(`sumQL` ~ sliceOp) += mixin(`(*pQ)` ~ sliceOp) * mixin(`(*pL)` ~ sliceOp);

                    ++pI; ++pQ; ++pP; ++pE; ++pL;
                }

                foreach(j; 0 .. VectorizedN){
                    I[0] += mixin(`sumIP` ~ getElem ~ `[j]`);
                    I[1] += mixin(`sumIE` ~ getElem ~ `[j]`);
                    I[2] += mixin(`sumIL` ~ getElem ~ `[j]`);
                    Q[0] += mixin(`sumQP` ~ getElem ~ `[j]`);
                    Q[1] += mixin(`sumQE` ~ getElem ~ `[j]`);
                    Q[2] += mixin(`sumQL` ~ getElem ~ `[j]`);
                }
            }
        };

        foreach(i; 0 .. packedLength / SubN){
           mixin(statement.format("SubN"));
        }

        immutable LeftN = packedLength % SubN;
        mixin(statement.format("LeftN"));
    }

    I[0 .. 1 + 2 * ns] *= CSCALE;
    Q[0 .. 1 + 2 * ns] *= CSCALE;
}


/* cumulative sum of correlation output -----------------------------------------
* phase/frequency lock loop (2nd order PLL with 1st order FLL)
* carrier frequency is computed
* args   : double *I        I   correlation output in 1ms (in-phase)
*          double *Q        I   correlation output in 1ms (quadrature-phase)
*          sdrtrk_t trk     I/0 sdr tracking struct
*          int    flag1     I   reset flag 1
*          int    flag2     I   reset flag 2
* return : none
*------------------------------------------------------------------------------*/
/** 相関値を積分するアレ
*/
void cumsumcorr(string file = __FILE__, size_t line = __LINE__)(ref sdrtrk_t trk, int flag1, int flag2)
{
    traceln("called");

    if (!flag1||(flag1&&flag2)) {
        trk.oldsumI[] = trk.sumI[];
        trk.oldsumQ[] = trk.sumQ[];
        trk.sumI[] = trk.I[];
        trk.sumQ[] = trk.Q[];
    }else{
        trk.sumI[] += trk.I[];
        trk.sumQ[] += trk.Q[];
    }
}


/* phase/frequency lock loop ----------------------------------------------------
* phase/frequency lock loop (2nd order PLL with 1st order FLL)
* carrier frequency is computed
* args   : sdrch_t *sdr     I/0 sdr channel struct
*          sdrtrkprm_t *prm I   sdr tracking prameter struct
* return : none
*------------------------------------------------------------------------------*/
void pll(string s)(ref sdrch_t sdr)
if(s == "1" || s == "2")
in{
    assert(sdr.trk.sumI[0].isValidNum);
    assert(sdr.trk.sumQ[0].isValidNum);
    assert(sdr.trk.oldsumI[0].isValidNum);
    assert(sdr.trk.oldsumQ[0].isValidNum);
}
out{
    assert(sdr.trk.carrNco.isValidNum);
    assert(sdr.trk.carrfreq.isValidNum);
    assert(sdr.trk.carrErr.isValidNum);
}
body{
    traceln("called");

    // s=="1"のときはsdr.trk.prm1に、s=="2"のときはsdr.trk.prm2になる。
    immutable prm = mixin("sdr.trk.prm" ~ s);

    immutable IP = sdr.trk.sumI[0],
              QP = sdr.trk.sumQ[0],
              oldIP = sdr.trk.oldsumI[0],
              oldQP = sdr.trk.oldsumQ[0],
              carrErr = atan(QP, IP) / DPI,
              freqErr = atan2(cast(real)oldIP*QP-IP*oldQP, fabs(oldIP*IP)+fabs(oldQP*QP))/PI;

    /* 2nd order PLL with 1st order FLL */
    sdr.trk.carrNco += prm.pllaw * (carrErr - sdr.trk.carrErr)
                     + prm.pllw2 * prm.dt * carrErr
                     + prm.fllw  * prm.dt * freqErr;

    sdr.trk.carrfreq = sdr.acq.acqfreqf + sdr.trk.carrNco;
    sdr.trk.carrErr = carrErr;
}


/* delay lock loop --------------------------------------------------------------
* delay lock loop (2nd order DLL)
* code frequency is computed
* args   : sdrch_t *sdr     I/0 sdr channel struct
*          sdrtrkprm_t *prm I   sdr tracking prameter struct
* return : none
*------------------------------------------------------------------------------*/
void dll(string s)(ref sdrch_t sdr)
if(s == "1" || s == "2")
in{
    assert(sdr.trk.sumI[sdr.trk.prm1.ne].isValidNum);
    assert(sdr.trk.sumI[sdr.trk.prm1.nl].isValidNum);
    assert(sdr.trk.sumQ[sdr.trk.prm1.ne].isValidNum);
    assert(sdr.trk.sumQ[sdr.trk.prm1.nl].isValidNum);

    immutable prm = mixin("sdr.trk.prm" ~ s);

    assert(prm.dllaw.isValidNum);
    assert(sdr.trk.codeErr.isValidNum);
    assert(prm.dllw2.isValidNum);
    assert(prm.dt.isValidNum);

    assert(sdr.crate.isValidNum);
    assert(sdr.trk.codeNco.isValidNum);
    assert(sdr.trk.carrfreq.isValidNum);
    assert(sdr.f_if.isValidNum);
    assert(Constant.get!"freq"(sdr.ctype).isValidNum);
}
out{
    assert(sdr.trk.codeNco.isValidNum);
    assert(sdr.trk.codefreq.isValidNum);
    assert(sdr.trk.codeErr.isValidNum);
}
body{
    static real cpxAbsSq(real i, real q) pure nothrow @safe { return i^^2 + q^^2; }

    traceln("called");

    immutable prm = mixin("sdr.trk.prm" ~ s);

    immutable ne = sdr.trk.prm1.ne,
              nl = sdr.trk.prm1.nl,
              IE = sdr.trk.sumI[ne],
              IL = sdr.trk.sumI[nl],
              QE = sdr.trk.sumQ[ne],
              QL = sdr.trk.sumQ[nl],
              IEQE = cpxAbsSq(IE, QE),
              ILQL = cpxAbsSq(IL, QL),
              codeErr = (IEQE + ILQL) != 0 ? ((IEQE - ILQL) / (IEQE + ILQL)) : 0;
  
    enforce(codeErr.isValidNum);

    /* 2nd order DLL */
    sdr.trk.codeNco += prm.dllaw * (codeErr - sdr.trk.codeErr)
                     + prm.dllw2 * prm.dt * codeErr;

    sdr.trk.codefreq = sdr.crate - sdr.trk.codeNco + (sdr.trk.carrfreq - sdr.f_if) / (Constant.get!"freq"(sdr.ctype) / sdr.crate); /* carrier aiding */
    sdr.trk.codeErr = codeErr;
}


/* set observation data ---------------------------------------------------------
* calculate doppler/carrier phase/SNR
* args   : sdrch_t *sdr     I   sdr channel struct
*          ulong buffloc I   current buffer location
*          ulong cnt     I   current counter of sdr channel thread
*          sdrtrk_t trk     I/0 sdr tracking struct
*          int    snrflag   I   SNR calculation flag
* return : none
*------------------------------------------------------------------------------*/
void setobsdata(ref sdrch_t sdr, ulong buffloc, ulong cnt, int snrflag)
{
    void shiftBack(E)(E[] r) { r[0 .. $-1].retro.copy(r[1 .. $].retro); }

    // シフトレジスタ達を一つ右にシフトする
    foreach(s; TypeTuple!("tow", "L", "D", "codei", "cntout", "remcodeout"))
        with(sdr.trk) shiftBack(mixin(s)[]);

    sdr.trk.tow[0] = sdr.nav.firstsftow + (cast(double)(cnt-sdr.nav.firstsfcnt)) / 1000;
    sdr.trk.codei[0] = buffloc;
    sdr.trk.cntout[0] = cnt;
    sdr.trk.remcodeout[0] = sdr.trk.oldremcode * sdr.f_sf / sdr.trk.codefreq;

    /* doppler */
    sdr.trk.D[0] = sdr.trk.carrfreq - sdr.f_if;

    /* carrier phase */
    //if (!sdr.trk.flagremcarradd) {
    //    immutable tmpL = sdr.trk.L[0];

    //    sdr.trk.L[0]+=sdr.trk.remcarr/DPI;
    //    sdr.trk.flagpolarityadd = true;

    //    (sdr.ctype == CType.L1CA) && writefln("%s [cyc] + (%s / DPI)[cyc] -> %s [cyc]", tmpL, sdr.trk.remcarr, sdr.trk.L[0]);
    //}

    //if (sdr.flagnavpre&&!sdr.trk.flagpolarityadd) {
    //    if (sdr.nav.polarity==-1) { sdr.trk.L[0]+=0.5; }
    //    sdr.trk.flagpolarityadd = true;
    //}

    sdr.trk.L[0] = sdr.trk.L[1] + sdr.trk.D[0] * sdr.trk.prm2.dt;

    sdr.trk.Isum += abs(sdr.trk.sumI[0]);
    sdr.trk.Qsum += abs(sdr.trk.sumQ[0]);
    if (snrflag){
        shiftBack(sdr.trk.S[]);
        shiftBack(sdr.trk.codeisum[]);

        /* signal to noise ratio */
        sdr.trk.S[0] = 20 * log10(sdr.trk.Isum / sdr.trk.Qsum);
        sdr.trk.codeisum[0] = buffloc;
        sdr.trk.Isum = 0;
        sdr.trk.Qsum = 0;
    }
}
