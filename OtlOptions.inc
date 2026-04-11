///<summary>Common compilation settings and conditional defines for the OmniThreadLibrary project.</summary>
///<author>Primoz Gabrijelcic</author>
///<license>
///This software is distributed under the BSD license.
///
///Copyright (c) 2019 Primoz Gabrijelcic
///All rights reserved.
///
///Redistribution and use in source and binary forms, with or without modification,
///are permitted provided that the following conditions are met:
///- Redistributions of source code must retain the above copyright notice, this
///  list of conditions and the following disclaimer.
///- Redistributions in binary form must reproduce the above copyright notice,
///  this list of conditions and the following disclaimer in the documentation
///  and/or other materials provided with the distribution.
///- The name of the Primoz Gabrijelcic may not be used to endorse or promote
///  products derived from this software without specific prior written permission.
///
///THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
///ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
///WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
///DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
///ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
///(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
///LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
///ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
///(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
///SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
///</license>
///<remarks><para>
///   Author            : Primoz Gabrijelcic
///   Creation date     : 2010-07-01
///   Last modification : 2026-04-11
///   Version           : 3.0
///</para><para>
///   History:
///     3.0: 2026-04-11
///       - OTL NG: Minimum Delphi version raised to 11 Alexandria.
///       - Removed all pre-Delphi 11 version checks and conditionals.
///       - All version-gated defines are now unconditionally set (transitional;
///         will be removed from usage sites as individual units are updated).
///       - Removed OTL_ForceThreadTracking (XE2-only workaround).
///       - Added OTL_HasAPC for Windows (gates QueueUserAPC-based fast path).
///       - OTL_PlatformIndependent is now a manual testing flag on Windows;
///         auto-set on non-Windows platforms.
///     2.01: 2018-05-28
///       - Introduced OTL_NameThreadHasStringParameter and OTL_HasVolatileAttribute.
///     1.06: 2019-01-03
///       - Introduced OTL_TypeInfoHasTypeData.
///     1.05: 2018-05-26
///       - Introduced OTL_NameThreadHasStringParameter and OTL_CanInlineOperators.
///       - OTL_StrPasInAnsiStrings moved from XE5 to XE4 section.
///     2.0: 2018-05-12
///       - Removed defines associated with Delphi 2007 do XE as these versions are
///         no longer supported.
///     1.04: 2012-09-23
///       - Introduced OTL_HasSystemTypes and OTL_LongGetMethodInfo.
///     1.03: 2011-07-23
///       - Assertions must be always enabled.
///     1.02: 2010-12-02
///       - Removed OTL_ParallelAggregate.
///     1.01: 2010-07-25
///       - Introduced OTL_ParallelAggregate.
///     1.0: 2010-07-01
///       - Released.
///</para></remarks>

// Defines below this point should not be changed. Changing them could break OmniThreadLibrary.

{$IF CompilerVersion < 35}
{$MESSAGE ERROR 'OmniThreadLibrary NG requires Delphi 11 Alexandria or newer'}
{$IFEND}

{$ALIGN 8}
{$BOOLEVAL OFF}
{$EXTENDEDSYNTAX ON}
{$LONGSTRINGS ON}
{$MINENUMSIZE 1}
{$OPENSTRINGS ON}
{$OVERFLOWCHECKS OFF}
{$TYPEDADDRESS OFF}
{$ASSERTIONS ON}
{$TYPEINFO OFF}
{$ZEROBASEDSTRINGS OFF}

// Transitional defines — always true with Delphi 11+.
// Kept until usage sites are cleaned up in individual units (Phase 1 steps 1.2–1.7).
{$DEFINE OTL_CountdownHasSpinCount}
{$DEFINE OTL_NameThreadHasStringParameter}
{$DEFINE OTL_TypeInfoHasTypeData}
{$DEFINE OTL_VariantHasInt64}
{$DEFINE OTL_StrPasInAnsiStrings}
{$DEFINE OTL_HasVolatileAttribute}
{$DEFINE OTL_FixedGenericIncompletelyDefined}
{$DEFINE OTL_MobileSupport}
{$DEFINE OTL_CanInlineOperators}
{$DEFINE OTL_HasForceQueue}
{$DEFINE OTL_HasLightweightMREW}

// Platform-specific defines

{$IFDEF MSWINDOWS}
  {$DEFINE OTL_HaveCmpx16b}  // Opt-in 128-bit CAS fast path (Windows x86/x64 only)
  {$DEFINE OTL_HasAPC}        // Gates QueueUserAPC-based fast path on Windows
{$ELSE}
  {$UNDEF OTL_HaveCmpx16b}
{$ENDIF}

// On non-Windows platforms, platform-independent code paths are mandatory.
// On Windows, define OTL_PlatformIndependent manually to force platform-independent
// code paths for testing purposes.
{$IFNDEF MSWINDOWS}
  {$DEFINE OTL_PlatformIndependent}
{$ENDIF}
