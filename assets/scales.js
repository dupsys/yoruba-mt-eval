// Rating values: identical to the Excel workbooks and to the database CHECK constraints, so exports feed
// reports/human_eval/analyze_human_eval.py unchanged.
export const ADEQ = ["5 - all meaning preserved", "4 - most meaning", "3 - much meaning", "2 - little meaning", "1 - none"];
export const FLU = ["5 - flawless", "4 - good", "3 - non-native", "2 - disfluent", "1 - incomprehensible"];
export const ORTH = ["Correct", "Minor diacritic errors", "Major diacritic errors", "Not applicable (English output)"];
export const ORTH_NA = "Not applicable (English output)";
export const PREF = ["A better", "B better", "Equal", "Cannot judge"];
export const ERR = ["None", "Mistranslation", "Omission", "Addition / hallucination", "Untranslated / wrong language",
  "Name or number", "Terminology", "Idiom or proverb meaning", "Register / honorific", "Diacritics / orthography",
  "Grammar / fluency", "Repetition / malformed"];
export const REQUIRED = ["adequacy_a", "adequacy_b", "fluency_a", "fluency_b", "orthography_a", "orthography_b",
  "preference", "main_error"];
// Export columns, in the workbook's order.
export const EXPORT_COLUMNS = [
  ["Item ID", "item_id"], ["Comparison", "comparison"], ["Direction", "direction"], ["Domain", "domain"],
  ["Source", "source"], ["Output A", "output_a"], ["Output B", "output_b"], ["Adequacy A", "adequacy_a"],
  ["Adequacy B", "adequacy_b"], ["Fluency A", "fluency_a"], ["Fluency B", "fluency_b"],
  ["Orthography A", "orthography_a"], ["Orthography B", "orthography_b"], ["Preference", "preference"],
  ["Main error (worse output)", "main_error"], ["Comment", "comment"],
  ["Display problem", "display_problem"]];
