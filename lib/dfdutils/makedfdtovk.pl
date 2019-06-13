#!/usr/bin/perl

# N.B. 0 arguments, read stdin, write stdout.
# 1 argument, read ARGV[0], write stdout.
# 2 arguments, read ARGV[1], write ARGV[2].
if (@ARGV > 1) {
    open (my $output, '>', $ARGV[1]);
    select $output;
}

# Endianness is a parameter to the (non-block-compressed) generators
# This doesn't have to be a number: $bigEndian = "myBigEndianFlag" will drop this argument in the generated code
$bigEndian = 0;

# Keep track of formats we've seen to avoid duplicates
%foundFormats = ();

# Loop over each line of input
while ($line = <>) {

    # Match any format that starts with a channel description (some number of R, G, B, A or a number)
    # In PERL, "=~" performs a regex operation on the left argument
    # m/<regex>/ matches the regular expression
    if ($line =~ m/VK_FORMAT_[RGBA0-9]+_/) {

        # Set $format to the enum identifier
        ($line =~ m/(VK_FORMAT[A-Z0-9_]+)/);

        # $<number> holds the <number>'th parenthesised entry in the previous regex
        # (only one in this case)
        $format = $1;

        # Skip a format if we've already processed it
        if (!exists($foundFormats{$format})) {

            # Packed formats end "_PACK<n>" - is this format packed?
            if ($format =~ m/_PACK/) {

                # Extract the channel identifiers and suffix from the packed format
                $format =~ m/VK_FORMAT_([RGBA0-9]+)_([^_]+)_PACK[0-9]+/;

                # The first parenthesised bit of regex is the channels ("R5G5B5" etc.)
                $channels = $1;

                # The second parenthesised bit of regex is the suffix ("UNORM" etc.)
                $suffix = $2;

                # N.B. We don't care about the total bit count (after "PACK" in the name)

                # Create an empty array of channel names and corresponding bits
                @packChannels = ();
                @packBits = ();

                # Loop over channels, separating out the last letter followed by a number
                while ($channels =~ m/([RGBA0-9]*)([RGBA])([0-9]+)/) {

                    # Add the rightmost channel name to our array
                    push @packChannels, $2;

                    # Add the rightmost channel bits to the array
                    push @packBits, $3;

                    # Truncate the channels string to remove the channel we've processed
                    $channels = $1;
                }

                # The number of channels we've found is the array length we've built
                $numChannels = @packChannels;

                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;

                # If we're not packed, do we have a simple RGBA channel size list with a suffix?
                # N.B. We don't want to pick up downsampled or planar formats, which have more _-separated fields
                # - "$" matches the end of the format identifier
            } elsif ($format =~ m/VK_FORMAT_([RGBA0-9]+)_([^_]+)$/) {

                # Extract our "channels" (e.g. "B8G8R8") and "suffix" (e.g. "UNORM")
                $channels = $1;
                $suffix = $2;

                # Non-packed format either start with red (R8G8B8A8) or blue (B8G8R8A8)
                # We have a special case to notice when we start with blue
                if (substr($channels,0,1) eq "B") {                    
                    # Red and blue are swapped (B, G, R, A) - record this
                    # N.B. createDFDUnpacked() just knows this and R,G,B,A channel order, not arbitrary
                    $rbswap = 1;

                    # We know we saw "B" for blue, so we must also have red and green
                    $numChannels = 3;

                    # If we have "A" in the channels as well, we have four channels
                    if ($channels =~ m/A/) {
                        $numChannels = 4;
                    }
                } else {

                    # We didn't start "B", so we're in conventional order (R, G, B, A)
                    $rbswap = 0;

                    # Check for the channel names present and map that to the number of channels
                    if ($channels =~ m/A/) {
                        $numChannels = 4;
                    } elsif ($channels =~ m/B/) {
                        $numChannels = 3;
                    } elsif ($channels =~ m/G/) {
                        $numChannels = 2;
                    } else {
                        $numChannels = 1;
                    }
                }

                # In an unpacked format, all the channels are the same size, so we only need to check one
                $channels =~ m/R([0-9]+)/;

                # For unpacked, we need bytes per channel, not bits
                $bytesPerChannel = $1 / 8;
                
                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;
            }
        }

        # If we weren't VK_FORMAT_ plus a channel, we might be a compressed format, that ends "_BLOCK"
        # N.B. We don't currently process compressed formats here.
        # They're essentially all special cases anyway.
        # The decoding code that this is derived from is retained for future work.
    } elsif (0 && $line =~ m/(VK_FORMAT_[A-Z0-9x_]+_BLOCK)/) {

        # Extract the format identifier from the rest of the line
        $format = $1;

        # Skip a format if we've already processed it
        if (!exists($foundFormats{$format})) {

            # Special-case BC1_RGB to separate it from BC1_RGBA
            if ($line =~ m/VK_FORMAT_BC1_RGB_([A-Z]+)_BLOCK/) {

                # Pull out the suffix ("UNORM" etc.)
                $suffix = $1;

                # Output the special case - a 4x4 BC1 block
                print "case $format: return createDFDCompressed(c_BC1_RGB, 4, 4, s_$suffix);\n";

                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;

                # Special case BC1_RGBA (but still extract the suffix with a regex)
            } elsif ($line =~ m/VK_FORMAT_BC1_RGBA_([A-Z]+)_BLOCK/) {
                $suffix = $1;
                print "case $format: return createDFDCompressed(c_BC1_RGBA, 4, 4, s_$suffix);\n";

                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;

                # All the other BC formats don't have a channel identifier in the name, so we regex match them
            } elsif ($line =~ m/VK_FORMAT_(BC[2-7H])_([A-Z]+)_BLOCK/) {
                $scheme = $1;
                $suffix = $2;
                print "case $format: return createDFDCompressed(c_$scheme, 4, 4, s_$suffix);\n";

                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;

                # The ETC and EAC formats have two-part names (ETC2_R8G8B8, EAC_R11 etc.) starting with "E"
            } elsif ($line =~ m/VK_FORMAT_(E[^_]+_[^_]+)_([A-Z]+)_BLOCK/) {
                $scheme = $1;
                $suffix = $2;
                print "case $format: return createDFDCompressed(c_$scheme, 4, 4, s_$suffix);\n";

                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;

                # Finally, ASTC, the only case where the block size is a parameter
            } elsif ($line =~ m/VK_FORMAT_ASTC_([0-9]+)x([0-9]+)_([A-Z]+)_BLOCK/) {
                $w = $1;
                $h = $2;
                $suffix = $3;
                print "case $format: return createDFDCompressed(c_ASTC, $w, $h, s_$suffix);\n";

                # Add the format we've processed to our "done" hash
                $foundFormats{$format} = 1;
            }

            # Currently PVRTC drops through unmatched, pending support
        }
    }

    # ...and continue to the next line
}

# Now generate the output for any formats we've seen.

sub checkSuffices {
    my $formatPrefix = shift(@_);
    my $packSuffix = shift(@_);

    # Only output tests for formats that exist.
    # Simplify things by picking off sRGB and float (always signed for unpacked) first.
    if (exists($foundFormats{"VK_FORMAT_" . $formatPrefix . "_SRGB" . $packSuffix})) {
        print "        if ((r & i_SRGB_FORMAT_BIT)) return VK_FORMAT_" . $formatPrefix . "_SRGB;\n";
    }
    if (exists($foundFormats{"VK_FORMAT_" . $formatPrefix . "_SFLOAT" . $packSuffix})) {
        print "        if ((r & i_FLOAT_FORMAT_BIT)) return VK_FORMAT_" . $formatPrefix . "_SFLOAT;\n";
    }
    if (exists($foundFormats{"VK_FORMAT_" . $formatPrefix . "_UNORM" . $packSuffix})) {
        print "        if ((r & i_NORMALIZED_FORMAT_BIT) && !(r & i_SIGNED_FORMAT_BIT)) return VK_FORMAT_" . $formatPrefix . "_UNORM;\n";
    }
    if (exists($foundFormats{"VK_FORMAT_" . $formatPrefix . "_SNORM" . $packSuffix})) {
        print "        if ((r & i_NORMALIZED_FORMAT_BIT) && (r & i_SIGNED_FORMAT_BIT)) return VK_FORMAT_" . $formatPrefix . "_SNORM;\n";
    }
    if (exists($foundFormats{"VK_FORMAT_" . $formatPrefix . "_UINT" . $packSuffix})) {
        print "        if (!(r & i_NORMALIZED_FORMAT_BIT) && !(r & i_SIGNED_FORMAT_BIT)) return VK_FORMAT_" . $formatPrefix . "_UINT;\n";
    }
    if (exists($foundFormats{"VK_FORMAT_" . $formatPrefix . "_SINT" . $packSuffix})) {
        print "        if (!(r & i_NORMALIZED_FORMAT_BIT) && (r & i_SIGNED_FORMAT_BIT)) return VK_FORMAT_" . $formatPrefix . "_SINT;\n";
    }
    # N.B. Drop through if the VKFORMAT doesn't exist.
}

$prefix = <<'END_PREFIX';
if (KHR_DFDVAL(dfd + 1, MODEL) == KHR_DF_MODEL_RGBSDA) {
  InterpretDFDResult r;
  InterpretedDFDChannel R = {0,0};
  InterpretedDFDChannel G = {0,0};
  InterpretedDFDChannel B = {0,0};
  InterpretedDFDChannel A = {0,0};
  uint32_t wordBytes;

  r = interpretDFD(dfd, &R, &G, &B, &A, &wordBytes);

  if (r & i_UNSUPPORTED_ERROR_BIT) return VK_FORMAT_UNDEFINED;

  if (r & i_PACKED_FORMAT_BIT) {
END_PREFIX

print $prefix;

# Packed format decode.
# There aren't many of these, so we hard-wire them (and identify them minimally).

$packedDecode = << 'END_PACKED';
    if (wordBytes == 1) return VK_fORMAT_R4G4_UNORM_PACK8;
    else if (wordBytes == 2) { /* PACK16 */
      if (A.size == 4) {
        if (R.offset == 12) return VK_FORMAT_R4G4B4A4_UNORM_PACK16;
        else return VK_FORMAT_B4G4R4A4_UNORM_PACK16;
      } else if (A.size == 0) { /* Three channels */
        if (B.offset == 0) return VK_FORMAT_R5G6B5_UNORM_PACK16;
        else return VK_FORMAT_B5G6R5_UNORM_PACK16;
      } else return VK_FORMAT_A1R5G5B5_UNORM_PACK16;
    } else if (wordBytes == 4) { /* PACK32 */
END_PACKED

print $packedDecode;

print "    if (A.size == 8) {\n";
checkSuffices("A8B8G8R8", "_PACK32");
print "    } else if (A.size == 2 && B.offset == 0) {\n";
checkSuffices("A2R10G10B10", "_PACK32");
print "    } else if (A.size == 2 && R.offset == 0) {\n";
checkSuffices("A2B10G10R10", "_PACK32");
print "    } else if (R.size == 11) return VK_FORMAT_B10G11R11_UFLOAT_PACK32;\n";
print "  } else { /* Not a packed format */\n";

# Start by checking sizes
for ($byteSize = 1; $byteSize <= 8; $byteSize <<= 1) {
    if ($byteSize == 1) {
        print "    if (wordBytes == $byteSize) {\n";
    } else {
        print "    } else if (wordBytes == $byteSize) {\n";
    }
    # If we have an alpha channel...
    print "      if (A.size > 0) { /* 4 channels */\n";
    print "        if (R.offset == 0) { /* RGBA */\n";
    checkSuffices("R" . 8 * $byteSize . "G" . 8 * $byteSize . "B" . 8 * $byteSize . "A" . 8 * $byteSize, "");
    print "        } else { /* BGRA */\n";
    checkSuffices("B" . 8 * $byteSize . "G" . 8 * $byteSize . "R" . 8 * $byteSize . "A" . 8 * $byteSize, "");
    print "        }\n";
    print "      } else if (B.size > 0) { /* 3 channels */\n";
    print "        if (R.offset == 0) { /* RGB */\n";
    checkSuffices("R" . 8 * $byteSize . "G" . 8 * $byteSize . "B" . 8 * $byteSize, "");
    print "        } else { /* BGR */\n";
    checkSuffices("B" . 8 * $byteSize . "G" . 8 * $byteSize . "R" . 8 * $byteSize, "");
    print "        }\n";
    print "      } else if (G.size > 0) { /* 2 channels */\n";
    checkSuffices("R" . 8 * $byteSize . "G" . 8 * $byteSize, "");
    print "      } else { /* 1 channel */\n"; # Red only
    checkSuffices("R" . 8 * $byteSize, "");
    print "      }\n";
}
print "    }\n";
print "  }\n";

$compressedDecode = << 'END_COMPRESSED';
} else if (KHR_DFDVAL((dfd + 1), MODEL) >= 128) {
  const uint32_t *bdb = dfd + 1;
  switch (KHR_DFDVAL(bdb, MODEL)) {
  case KHR_KHR_DF_MODEL_BC1A:
    if (KHR_DFDSVAL(bdb, 0, CHANNELID) == KHR_DF_CHANNEL_BC1A_COLOR) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_BC1_RGB_UNORM_BLOCK;
      } else {
        return VK_FORMAT_BC1_RGB_SRGB_BLOCK;
      }
    } else {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_BC1_RGBA_UNORM_BLOCK;
      } else {
        return VK_FORMAT_BC1_RGBA_SRGB_BLOCK;
      }
    }
  case KHR_DF_MODEL_BC2:
    if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
      return VK_FORMAT_BC2_UNORM_BLOCK;
    } else {
      return VK_FORMAT_BC2_SRGB_BLOCK;
    }
  case KHR_DF_MODEL_BC3:
    if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
      return VK_FORMAT_BC3_UNORM_BLOCK;
    } else {
      return VK_FORMAT_BC3_SRGB_BLOCK;
    }
  case KHR_DF_MODEL_BC4:
    if (!(KHR_DFDSVAL(bdb, 0, FLAGS) & KHR_DF_SAMPLE_DATATYPE_SIGNED)) {
      return VK_FORMAT_BC4_UNORM_BLOCK;
    } else {
      return VK_FORMAT_BC4_SNORM_BLOCK;
    }
  case KHR_DF_MODEL_BC5:
    if (!(KHR_DFDSVAL(bdb, 0, FLAGS) & KHR_DF_SAMPLE_DATATYPE_SIGNED)) {
      return VK_FORMAT_BC5_UNORM_BLOCK;
    } else {
      return VK_FORMAT_BC5_SNORM_BLOCK;
    }
  case KHR_DF_MODEL_BC6H:
    if (!(KHR_DFDSVAL(bdb, 0, FLAGS) & KHR_DF_SAMPLE_DATATYPE_SIGNED)) {
      return VK_FORMAT_BC6H_UFLOAT_BLOCK;
    } else {
      return VK_FORMAT_BC6H_SFLOAT_BLOCK;
    }
  case KHR_DF_MODEL_BC7:
    if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
      return VK_FORMAT_BC7_UNORM_BLOCK;
    } else {
      return VK_FORMAT_BC7_SRGB_BLOCK;
    }
  case KHR_DF_MODEL_ETC2:
    if (KHR_DFDSVAL(bdb, 0, CHANNELID) == KHR_DF_CHANNEL_ETC2_COLOR) {
      if (KHR_DFDVAL(bdb, DESCRIPTORBLOCKSIZE) == 40) {
        if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
          return VK_FORMAT_ETC2_R8G8B8_UNORM_BLOCK;
        } else {
          return VK_FORMAT_ETC2_R8G8B8_SRGB_BLOCK;
        }
      } else {
        if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
          return VK_FORMAT_ETC2_R8G8B8A1_UNORM_BLOCK;
        } else {
          return VK_FORMAT_ETC2_R8G8B8A1_SRGB_BLOCK;
        }
      }
    } else if (KHR_DFDSVAL(bdb, 0, CHANNELID) == KHR_DF_CHANNEL_ETC2_ALPHA) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK;
      }
    } else if (KHR_DFDVAL(bdb, DESCRIPTORBLOCKSIZE) == 40) {
      if (!(KHR_DFDSVAL(bdb, 0, FLAGS) & KHR_DF_SAMPLE_DATATYPE_SIGNED)) {
        return VK_FORMAT_EAC_R11_UNORM_BLOCK;
      } else {
        return VK_FORMAT_EAC_R11_SNORM_BLOCK;
      }
    } else {
      if (!(KHR_DFDSVAL(bdb, 0, FLAGS) & KHR_DF_SAMPLE_DATATYPE_SIGNED)) {
        return VK_FORMAT_EAC_R11G11_UNORM_BLOCK;
      } else {
        return VK_FORMAT_EAC_R11G11_SNORM_BLOCK;
      }
    }
  case KHR_DF_MODEL_ASTC:
    if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 3) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 3)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_4x4_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_4x4_SRGB_BLOCK;
      }
    } else if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 4) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 3)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_5x4_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_5x4_SRGB_BLOCK;
      }
    } else if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 4) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 4)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_5x5_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_5x5_SRGB_BLOCK;
      }
    } else if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 5) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 4)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_6x5_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_6x5_SRGB_BLOCK;
      }
    } else if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 5) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 5)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_6x6_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_6x6_SRGB_BLOCK;
      }
    } else if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 7) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 4)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_8x5_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_8x5_SRGB_BLOCK;
      }
    } else if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 7) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 5)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_8x6_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_8x6_SRGB_BLOCK;
      }
    } else if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 7) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 7)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_8x8_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_8x8_SRGB_BLOCK;
      }
    } else if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 9) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 4)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_10x5_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_10x5_SRGB_BLOCK;
      }
    } else if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 9) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 5)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_10x6_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_10x6_SRGB_BLOCK;
      }
    } else if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 9) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 7)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_10x8_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_10x8_SRGB_BLOCK;
      }
    } else if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 9) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 9)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_10x10_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_10x10_SRGB_BLOCK;
      }
    } else if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 11) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 9)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_12x10_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_12x10_SRGB_BLOCK;
      }
    } else if ((KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION0) == 11) &&
        (KHR_DFDVAL(bdb, TEXELBLOCKDIMENSION1) == 11)) {
      if (KHR_DFDVAL(bdb, TRANSFER) != KHR_DF_TRANSFER_SRGB) {
        return VK_FORMAT_ASTC_12x12_UNORM_BLOCK;
      } else {
        return VK_FORMAT_ASTC_12x12_SRGB_BLOCK;
      }
    }
  default:
  }
}
END_COMPRESSED

print $compressedDecode;

# Failed to match.
print "return VK_FORMAT_UNDEFINED; /* Drop-through for unmatched formats. */\n";