package com.ird.beyond.lo.test.util;

public class InspectDb {
    public static void main(String[] args) {
        try {
            System.out.println("\n================================================================================");
            System.out.println("VERIFYING CHECKLISTS IN DB");
            System.out.println("================================================================================");
            try {
                String val = DbSupport.queryScalar("SELECT string_agg(product_type_code || ':' || COALESCE(product_code, 'ALL') || '->' || COALESCE(doc_types_json, ''), '; ') FROM beyondcore.doc_checklist cl LEFT JOIN beyondcore.doc_chklst_dtls dtls ON dtls.checklist_id = cl.id");
                System.out.println("checklists = " + val);
            } catch (Exception e) {
                System.out.println("Error: " + e.getMessage());
            }
            System.out.println("================================================================================");
            System.out.println("================================================================================");

            DbSupport.closeAll();
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}
