package online;

import editors.ChartingState;
import Note;
import Note.PreloadedChartNote;
import Song.SwagSong;

typedef FunkinDiffInfo = {
    nps:Float, strain:Float
}

/**
 * Chart analysis for the online FP readout. Package paths are remapped to this engine
 * (`objects.Note` -> `Note`, `backend.Song.SwagSong` -> `Song.SwagSong`). Only Haxe
 * 4.2.5-legal syntax is used. The hurt-note test uses `Note.chartNoteTypeCausesMiss(noteType)`
 * to avoid constructing a `Note` (see `calc()`). Consumed by `FunkinPoints.devFP()`.
 */
class ChartAnalyzer {
    public static function calc(songData:SwagSong, mustPress:Bool):FunkinDiffInfo {
		// for 4k this will have 0000 bits
		// each 0 is another row for the key
		// if a bit is 1 then that means a note was registered there
		var unsortedChords:Map<String, Int> = [];
		for (sectIndex => section in songData.notes) {
			for (note in section.sectionNotes) {
                var daStrumTime:Float = note[0];
                var daNoteData:Int = Std.int(note[1] % Note.maniaKeys);
                if (note[1] < 0 || note[1] > Note.maniaKeys * 2 - 1)
                    continue;
                var gottaHitNote:Bool = PlayState.getMustPressFromRaw(section, note);
                if (gottaHitNote != mustPress) continue;

                /*
                 * The `Note` constructor is heavy (`initNote` builds a ColorSwap and an RGBShaderReference,
                 * and the 'Hurt Note' type calls `reloadNote('HURT')`), so the hurt test uses the equivalent
                 * predicate `Note.chartNoteTypeCausesMiss(noteType)` -- hitCausesMiss is exactly noteType ==
                 * 'Hurt Note'.
                 */
                var noteType:String = note[3];
			    if(!Std.isOfType(note[3], String)) noteType = NoteTypeRegistry.fromIndex(Std.int(note[3])); //Backward compatibility + compatibility with Week 7 charts

                //TODO maybe later add bad notes
                if (Note.chartNoteTypeCausesMiss(noteType)) {
                    continue;
                }

                // up to 32 rows sorry everyone, no 33k+
                var laneBit = 1 << daNoteData;

                // will merge notes within 2ms
                final timeKey:String = '${Math.round(daStrumTime / 2)}';

                if (unsortedChords.exists(timeKey))
                    unsortedChords.set(timeKey, unsortedChords.get(timeKey) | laneBit);
                else
                    unsortedChords.set(timeKey, laneBit);
            }
		}

		return chordsToDiff(unsortedChords);
	}

	/**
	 * chord map -> NPS / strain; shared by calc() and calcFromPreloaded().
	 */
	static function chordsToDiff(unsortedChords:Map<String, Int>):FunkinDiffInfo {
		// now just take the unsorted possible chords map 
		// the time is also converted back to regular miliseconds and it is also floatified
		var chords:Array<{
			time:Float,
			bits:Int,
		}> = [];
        for (time => bits in unsortedChords)
            chords.push({ time: Std.parseInt(time) * 2 / 1000.0, bits: bits });
        chords.sort(function(a, b) return Reflect.compare(a.time, b.time));

		if (chords.length < 2) return {
			nps: 0.0,
			strain: 0.0
		};

		var chord = chords[0];

		// NPS
		var TIMEFRAME_WINDOW:Float = 0.5;
		var totalNPSSum:Float = 0.0;
        var totalNPSWindows:Int = 0;
        var notesInCurrentWindow:Int = 0;
        var windowStartTime:Float = chord.time;
		function nextNPS() {
			notesInCurrentWindow += countBitChord(chord.bits);

            if (chord.time - windowStartTime >= TIMEFRAME_WINDOW) {
                final delta = chord.time - windowStartTime;
                final localNPS = notesInCurrentWindow / delta;

                if (localNPS > 0) {
                    totalNPSSum += localNPS;
                    totalNPSWindows++;
                }

                notesInCurrentWindow = 0;
                windowStartTime = chord.time;
            }
		}

		// STRAIN
        var currentStrain:Float = 0.0;
        var totalStrainSum:Float = 0.0;
        var prevTime:Float = chords[0].time;
        var DECAY_BASE:Float = 0.5; 
        var STRAIN_SCALING:Float = 1.5;
		function nextStrain() {
            var deltaTime = chord.time - prevTime;
            prevTime = chord.time;

            if (deltaTime <= 0.0) return;

            var noteCount = countBitChord(chord.bits);
			var additionValue = Math.exp(-12.0 * deltaTime) * noteCount;
			var decay = Math.pow(DECAY_BASE, deltaTime);

			currentStrain = (currentStrain * decay) + additionValue;
			totalStrainSum += currentStrain;
		}

        for (nextChord in chords) {
			chord = nextChord;

            nextNPS();
			nextStrain();
        }

        return {
			nps: totalNPSWindows > 0 ? (totalNPSSum / totalNPSWindows) : 0.0,
			strain: (totalStrainSum / chords.length) * STRAIN_SCALING
		};
	}

	/**
	 * PreloadedChartNote variant of calc(): large charts stream their bytes so sectionNotes never
	 * enter memory, but generateSong already converted the same notes to PreloadedChartNote.
	 *
	 * Differences from calc() (deliberate deviation, affects only the online FP readout):
	 *   - lane: calc() uses raw note[1] % Note.maniaKeys; here the key count the note was written
	 *     for (pn.mania, a 0-based index; -1 follows the current chart), which is exactly how
	 *     PlayState.generateSong() normalised noteData (PlayState.hx:4179-4183);
	 *   - side: calc() calls PlayState.getMustPressFromRaw(); here pn.mustPress directly;
	 *   - type: calc() accepts a numeric noteType; here pn.noteType is already a string.
	 *
	 * Row access is allocation-free: one scratch DTO serves the whole scan (ChartNotes.rowAt)
	 * instead of the iterator's get(), which builds a fresh PreloadedChartNote per row -- the
	 * per-row allocation the column store exists to avoid on a huge streamed chart. A row a script
	 * has parked still comes back as its live DTO, so every field read here is the value the old
	 * iterator produced.
	 */
	public static function calcFromPreloaded(notes:ChartNotes, mustPress:Bool):FunkinDiffInfo {
		var unsortedChords:Map<String, Int> = [];
		if (notes != null) {
			final scratch:PreloadedChartNote = ChartNotes.scratchNote();
			final len:Int = notes.length;
			for (i in 0...len) {
				final pn:PreloadedChartNote = notes.rowAt(i, scratch);
				if (pn == null || pn.isSustainNote) continue;
				if (pn.mustPress != mustPress) continue;

				// Change-Mania charts mix key counts inside one file, so the lane is taken from the key
				// count the note was authored for; `% Note.maniaKeys` folded a 9K lane onto a 4K lane
				// whenever PlayState.mania had moved on.
				final noteMania:Int = pn.mania;
				final maniaKeys:Int = (noteMania >= 0 && noteMania < Note.ammo.length) ? Note.ammo[noteMania] : Note.maniaKeys;

				var daNoteData:Int = pn.noteData % maniaKeys;
				if (daNoteData < 0 || daNoteData > 31) continue;

				if (Note.chartNoteTypeCausesMiss(pn.noteType)) continue;

				var laneBit = 1 << daNoteData;
				final timeKey:String = '${Math.round(pn.strumTime / 2)}';

				if (unsortedChords.exists(timeKey))
					unsortedChords.set(timeKey, unsortedChords.get(timeKey) | laneBit);
				else
					unsortedChords.set(timeKey, laneBit);
			}
		}
		return chordsToDiff(unsortedChords);
	}

	static inline function countBitChord(bits:Int) {
		var count = 0;
		var temp = bits;
		while (temp > 0) {
			if ((temp & 1) == 1) count++;
			temp = temp >> 1;
		}
		return count;
	}
}
